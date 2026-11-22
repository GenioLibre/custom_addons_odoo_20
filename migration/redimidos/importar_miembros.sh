#!/usr/bin/env bash
set -euo pipefail
cd /
umask 077
source_ids=$(mktemp)
trap 'rm -f "$source_ids"' EXIT
runuser -u postgres -- psql -XAtq -v ON_ERROR_STOP=1 -p 5433 -d Redimidos > "$source_ids" <<'SQL'
SELECT json_agg(row_to_json(src) ORDER BY id) FROM (
 SELECT m.id, m.partner_id, m.member_code, m.member_status, m.membership_date,
        m.birth_date, m.baptism_date, m.spiritual_encounter_date, m.marital_status,
        m.current_position, m.spouse_id, m.predio_id, m.red_id, m.discipulado_id, m.celula_id,
        ARRAY(SELECT c.partner_id FROM church_member_child_rel c WHERE c.member_id=m.id) AS children
 FROM church_member m
) src;
SQL
chown odoo20 "$source_ids"
runuser -u odoo20 -- env IEM_SOURCE="$source_ids" /opt/odoo20/venv/bin/python /opt/odoo20/odoo/odoo-bin shell -c /etc/odoo20.conf -d redimidos20_ensayo --db_port=5432 --no-http <<'PY'
import json
import os
from pathlib import Path

if env.cr.dbname != "redimidos20_ensayo":
    raise ValueError("Destino inesperado")
env.cr.execute("SELECT pg_advisory_xact_lock(hashtext('redimidos18_miembros'))")
rows = json.loads(Path(os.environ["IEM_SOURCE"]).read_text())
members = env["church.member"].with_context(active_test=False, tracking_disable=True, mail_create_nosubscribe=True)
created = 0
seen = set()
def mapped(kind, sid):
    return env.ref(f"redimidos18.{kind}_{sid}").id if sid else False

for row in rows:
    key = f"member_{row['id']}"
    vals = {k: row[k] or False for k in ("member_code", "member_status", "membership_date", "birth_date",
            "baptism_date", "spiritual_encounter_date", "marital_status", "current_position")}
    vals["partner_id"] = mapped("partner", row["partner_id"])
    vals["spouse_id"] = mapped("partner", row["spouse_id"])
    for kind in ("predio", "red", "discipulado", "celula"):
        vals[kind + "_id"] = mapped(kind, row[kind + "_id"])
    children = {mapped("partner", sid) for sid in row["children"]}
    rec = env.ref("redimidos18." + key, raise_if_not_found=False)
    if not rec:
        if members.search_count([("partner_id", "=", vals["partner_id"])]):
            raise ValueError(f"Ficha sin conciliar para origen {row['id']}")
        # Call the standard ORM after the IEM override. Contacts and permissions
        # are imported independently; the override would edit both during create.
        from odoo.addons.iem_church_management.models.church_member import ChurchMember
        rec = super(ChurchMember, members).create(dict(vals, child_ids=[(6, 0, sorted(children))]))
        env["ir.model.data"].create({"module":"redimidos18", "name":key, "model":members._name, "res_id":rec.id, "noupdate":True})
        created += 1
    if rec._name != members._name or rec.id in seen or set(rec.child_ids.ids) != children:
        raise ValueError(f"Vínculo incorrecto para {key}")
    for field, expected in vals.items():
        value = rec[field]
        if rec._fields[field].type == "many2one":
            value = value.id
        elif rec._fields[field].type == "date" and value:
            value = value.isoformat()
        if (value or False) != expected:
            raise ValueError(f"Diferencia en {key}: {field}")
    seen.add(rec.id)
env.flush_all()
if len(rows) != 199 or len(seen) != len(rows) or members.search_count([]) != len(rows):
    raise ValueError("Conteo inesperado de fichas. Se revierte el lote.")
env.cr.commit()
print(f"Miembros vinculados: {len(seen)}. Creados: {created}. Reutilizados: {len(seen)-created}.")
PY
