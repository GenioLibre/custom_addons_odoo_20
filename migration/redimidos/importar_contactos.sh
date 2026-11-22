#!/usr/bin/env bash
set -euo pipefail
cd /
umask 077
source_ids=$(mktemp)
trap 'rm -f "$source_ids"' EXIT
runuser -u postgres -- psql -XAtq -v ON_ERROR_STOP=1 -p 5433 -d Redimidos > "$source_ids" <<'SQL'
SELECT json_agg(entry ORDER BY id) FROM (
 SELECT p.id,p.name,p.active,p.email,p.phone,p.mobile,p.street,p.street2,p.city,p.zip,p.is_company,p.parent_id,p.type,p.function,p.website,p.comment,p.vat,p.is_member,
 p.gender,p.district,p.membership_date,p.predio_id,p.red_id,p.discipulado_id,p.celula_id,
 c.code AS country_code, st.code AS state_code,sc.code AS state_country,
 it.name AS doc_name,to_jsonb(it)->>'l10n_pe_vat_code' AS doc_code,
 p.l10n_latam_identification_type_id AS doc_id,
 ARRAY(SELECT u.login FROM res_users u WHERE u.partner_id=p.id) AS logins,
 EXISTS(SELECT 1 FROM res_company co WHERE co.partner_id=p.id) AS company_partner
 FROM res_partner p LEFT JOIN res_country c ON c.id=p.country_id
 LEFT JOIN res_country_state st ON st.id=p.state_id LEFT JOIN res_country sc ON sc.id=st.country_id
 LEFT JOIN l10n_latam_identification_type it ON it.id=p.l10n_latam_identification_type_id
) entry;
SQL
chown odoo20 "$source_ids"
runuser -u odoo20 -- env IEM_SOURCE="$source_ids" /opt/odoo20/venv/bin/python /opt/odoo20/odoo/odoo-bin shell -c /etc/odoo20.conf -d redimidos20_ensayo --db_port=5432 --no-http <<'PY'
import json
import os
from pathlib import Path

if env.cr.dbname != "redimidos20_ensayo":
    raise ValueError("Destino inesperado")
env.cr.execute("SELECT pg_advisory_xact_lock(hashtext('redimidos18_contactos'))")
rows = json.loads(Path(os.environ["IEM_SOURCE"]).read_text())
ctx = dict(active_test=False, tracking_disable=True, mail_create_nosubscribe=True, mail_create_nolog=True)
partners = env["res.partner"].with_context(**ctx)
data = env["ir.model.data"]
mapping = {}
created = 0

def mark(key, rec):
    data.create({"module": "redimidos18", "name": key, "model": rec._name, "res_id": rec.id, "noupdate": True})

def unique(model, domain):
    found = env[model].with_context(active_test=False).search(domain, limit=2)
    if len(found) != 1:
        raise ValueError(f"Referencia geográfica sin coincidencia única: {domain}")
    return found.id

def document(row):
    if not row["doc_id"]:
        return False
    key = f"document_{row['doc_id']}"
    existing = env.ref("redimidos18." + key, raise_if_not_found=False)
    if existing:
        return existing.id
    names = row["doc_name"]
    name = (names.get("es_PE") or names.get("es_ES") or names.get("en_US") or next(iter(names.values()))) if isinstance(names, dict) else names
    types = env["iem.identification.type"].with_context(active_test=False)
    code = row["doc_code"]
    rec = types.search([("l10n_pe_vat_code","=",code)] if code else [("name","=ilike",name)], limit=2)
    if len(rec) > 1:
        raise ValueError(f"Tipo de identificación ambiguo: {key}")
    if not rec:
        rec = types.create({"name": name, "l10n_pe_vat_code": code or False})
    mark(key, rec)
    return rec.id

for row in rows:
    sid = row["id"]
    key = f"partner_{sid}"
    known = env.ref("redimidos18." + key, raise_if_not_found=False)
    candidates = set(known.ids if known else [])
    if row["logins"]:
        users = env["res.users"].with_context(active_test=False).search([("login","in",row["logins"])])
        candidates.update(users.partner_id.ids)
    if row["company_partner"]:
        companies = env["res.company"].search([])
        if len(companies) != 1:
            raise ValueError("Se esperaba una sola compañía de destino")
        candidates.add(companies.partner_id.id)
    if len(candidates)>1 or candidates.intersection(mapping.values()):
        raise ValueError(f"Conflicto de identidad para contacto origen {sid}")
    vals = {k: row[k] or False for k in ("name","email","phone","street","street2","city","zip","is_company","type","function","website","comment","vat","gender","district","membership_date")}
    vals.update(active=row["active"], iem_mobile=row["mobile"] or False, iem_identification_type_id=document(row))
    vals["country_id"] = unique("res.country",[("code","=",row["country_code"])]) if row["country_code"] else False
    vals["state_id"] = unique("res.country.state",[("country_id.code","=",row["state_country"]),("code","=",row["state_code"])]) if row["state_code"] else False
    for level in ("predio","red","discipulado","celula"):
        field = level + "_id"
        vals[field] = env.ref(f"redimidos18.{level}_{row[field]}").id if row[field] else False
    if candidates:
        rec = partners.browse(candidates.pop())
        rec.write(vals)
    else:
        rec = partners.create(vals)
        created += 1
    if rec.is_member != bool(row["is_member"]):
        rec.write({"is_member": bool(row["is_member"])})
    if not known:
        mark(key, rec)
    mapping[sid] = rec.id
for row in rows:
    rec = partners.browse(mapping[row["id"]])
    parent = mapping[row["parent_id"]] if row["parent_id"] else False
    if rec.parent_id.id != parent:
        rec.write({"parent_id": parent})
env.flush_all()
for row in rows:
    rec = partners.browse(mapping[row["id"]])
    if rec.parent_id.id != mapping.get(row["parent_id"], False) or rec.iem_mobile != (row["mobile"] or False):
        raise ValueError(f"Validación fallida: contacto origen {row['id']}")
if len(mapping) != 205 or len(set(mapping.values())) != 205:
    raise ValueError("No se pudieron conciliar los 205 contactos del ensayo")
env.cr.commit()
print(f"Contactos vinculados: {len(mapping)}. Creados en esta ejecución: {created}. Reutilizados: {len(mapping)-created}.")
PY
