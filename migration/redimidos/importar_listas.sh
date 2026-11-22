#!/usr/bin/env bash
set -euo pipefail
cd /
umask 077
source_ids=$(mktemp)
trap 'rm -f "$source_ids"' EXIT
runuser -u postgres -- psql -XAtq -v ON_ERROR_STOP=1 -p 5433 -d Redimidos > "$source_ids" <<'SQL'
SELECT json_build_array(
 (SELECT json_agg(x ORDER BY id) FROM (SELECT l.*, c.name AS currency_code,
 ARRAY(SELECT p.position_id FROM iem_church_member_list_position_rel p WHERE p.list_id=l.id) AS positions
 FROM iem_church_member_list l LEFT JOIN res_currency c ON c.id=l.currency_id) x),
 (SELECT json_agg(x ORDER BY id) FROM (SELECT id,list_id,member_id,source,extra_boolean,extra_amount,extra_text,create_uid,create_date,write_uid,write_date FROM iem_church_member_list_line) x)
);
SQL
chown odoo20 "$source_ids"
runuser -u odoo20 -- env IEM_SOURCE="$source_ids" /opt/odoo20/venv/bin/python /opt/odoo20/odoo/odoo-bin shell -c /etc/odoo20.conf -d redimidos20_ensayo --db_port=5432 --no-http <<'PY'
import json
import os
from pathlib import Path

if env.cr.dbname != "redimidos20_ensayo":
    raise ValueError("Destino inesperado")
env.cr.execute("SELECT pg_advisory_xact_lock(hashtext('redimidos18_listas'))")
rows = json.loads(Path(os.environ["IEM_SOURCE"]).read_text())
from datetime import datetime
from odoo.addons.iem_church_management.models.church_member_list import IemChurchMemberList, IemChurchMemberListLine
headers, lines = rows
if (len(headers),len(lines),sum(len(r["positions"]) for r in headers)) != (13,355,2):
    raise ValueError("El origen difiere del inventario de listas")
def mapped(kind, sid):
    return env.ref(f"redimidos18.{kind}_{sid}").id if sid else False

def save(row, model, cls, prefix, vals, positions=None):
    key = f"{prefix}_{row['id']}"
    uid = mapped("user",row["create_uid"])
    target = env[model].sudo().with_context(active_test=False,tracking_disable=True)
    rec = env.ref("redimidos18."+key,raise_if_not_found=False)
    if not rec:
        payload = vals.copy()
        if positions is not None:
            payload["position_filter_ids"] = [(6,0,positions)]
        rec = super(cls,target).create(payload)
        env["ir.model.data"].create({"module":"redimidos18","name":key,"model":model,"res_id":rec.id,"noupdate":True})
    if rec._name != model or not rec.exists():
        raise ValueError(f"Modelo o registro incorrecto en {key}")
    if positions is not None and set(rec.position_filter_ids.ids) != set(positions):
        raise ValueError(f"Cargos incorrectos en {key}")
    for field, expected in vals.items():
        value = rec[field]
        if rec._fields[field].type == "many2one":
            value = value.id
        if value != expected:
            raise ValueError(f"Diferencia en {key}: {field}")
    rec.flush_recordset()
    from odoo.tools import SQL
    writer = mapped("user",row["write_uid"])
    audit = ["create_uid","create_date","write_date","write_uid"]
    env.cr.execute(SQL("UPDATE %s SET create_uid=%s, create_date=%s, write_date=%s, write_uid=%s WHERE id=%s", SQL.identifier(rec._table),uid or None,row["create_date"],row["write_date"],writer or None,rec.id))
    rec.invalidate_recordset(audit)
    rec.modified(["create_uid"])
    if rec.create_uid.id != uid or rec.write_uid.id != writer:
        raise ValueError(f"Auditoría incorrecta después de restaurar {key}")
    return rec.id

header_model = "iem.church.member.list"
header_ids = set()
line_ids = set()
for row in headers:
    keys = "name active visibility website_registration_enabled vacancies gender member_status age_from age_to filter_summary details show_boolean_extra boolean_extra_label show_amount_extra amount_extra_label show_text_extra text_extra_label show_image_extra image_extra_label".split()
    vals = {k: row[k] if row[k] is not None else False for k in keys}
    for k in ("predio","red","discipulado","celula","scope_predio","scope_red","scope_discipulado"):
        vals[k+"_id"] = mapped(k.removeprefix("scope_"),row[k+"_id"])
    currency = env["res.currency"].with_context(active_test=False).search([("name","=",row["currency_code"])],limit=2)
    if len(currency)!=1:
        raise ValueError("No se encontró una moneda única")
    vals["currency_id"] = currency.id
    header_ids.add(save(row,header_model,IemChurchMemberList,"list",vals,[mapped("position",p) for p in row["positions"]]))
for row in lines:
    vals = {k:row[k] or False for k in ("source","extra_boolean","extra_text")}
    vals.update(extra_amount=row["extra_amount"] or 0.0,list_id=mapped("list",row["list_id"]),member_id=mapped("member",row["member_id"]))
    line_ids.add(save(row,header_model+".line",IemChurchMemberListLine,"list_line",vals))
env.flush_all()
for model, ids, expected in [(header_model,header_ids,13),(header_model+".line",line_ids,355)]:
    if len(ids)!=expected or env[model].with_context(active_test=False).search_count([])!=expected:
        raise ValueError(f"Conteo inesperado en {model}")
env.cr.commit()
print("Listas guardadas: 13. Líneas verificadas: 355. Vínculos con cargos: 2.")
PY
