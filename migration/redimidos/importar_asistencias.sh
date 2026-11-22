#!/usr/bin/env bash
set -euo pipefail
cd /
umask 077
source_ids=$(mktemp)
trap 'rm -f "$source_ids"' EXIT
runuser -u postgres -- psql -XAtq -v ON_ERROR_STOP=1 -p 5433 -d Redimidos > "$source_ids" <<'SQL'
SELECT json_build_array(
 (SELECT json_agg(h ORDER BY id) FROM (SELECT id,celula_id,week_year,week_number,week_start,week_end FROM iem_church_weekly_attendance) h),
 (SELECT json_agg(l ORDER BY id) FROM (SELECT id,attendance_id,member_id,attended_celula,attended_discipulado,attended_culto,tithed FROM iem_church_weekly_attendance_line) l)
);
SQL
chown odoo20 "$source_ids"
runuser -u odoo20 -- env IEM_SOURCE="$source_ids" /opt/odoo20/venv/bin/python /opt/odoo20/odoo/odoo-bin shell -c /etc/odoo20.conf -d redimidos20_ensayo --db_port=5432 --no-http <<'PY'
import json
import os
from pathlib import Path

if env.cr.dbname != "redimidos20_ensayo":
    raise ValueError("Destino inesperado")
env.cr.execute("SELECT pg_advisory_xact_lock(hashtext('redimidos18_asistencias'))")
rows = json.loads(Path(os.environ["IEM_SOURCE"]).read_text())
from datetime import date

headers, lines = rows
if (len(headers), len(lines)) != (160, 1132):
    raise ValueError("El origen difiere del inventario de este ensayo")
model = "iem.church.weekly.attendance"
ctx = dict(tracking_disable=True, active_test=False, mail_create_nosubscribe=True)
def import_row(target, key, values, seen):
    rec = env.ref("redimidos18." + key, raise_if_not_found=False)
    if not rec:
        rec = env[target].with_context(**ctx).create(values)
        env["ir.model.data"].create({"module":"redimidos18","name":key,"model":target,"res_id":rec.id,"noupdate":True})
    if rec._name != target or rec.id in seen or not rec.exists():
        raise ValueError(f"Identificador incompatible: {key}")
    for field, expected in values.items():
        actual = rec[field]
        if rec._fields[field].type == "many2one":
            actual = actual.id
        if actual != expected:
            raise ValueError(f"Diferencia en {key}: {field}")
    seen.add(rec.id)
    return rec.id

header_ids = {}
seen_headers, seen_lines = set(), set()
for row in headers:
    vals = {k:row[k] for k in ("week_year","week_number")}
    vals.update({k:date.fromisoformat(row[k]) for k in ("week_start","week_end")})
    vals["celula_id"] = env.ref(f"redimidos18.celula_{row['celula_id']}").id
    header_ids[row["id"]] = import_row(model, f"attendance_{row['id']}", vals, seen_headers)
for row in lines:
    vals = {k:bool(row[k]) for k in ("attended_celula","attended_discipulado","attended_culto","tithed")}
    vals.update(attendance_id=header_ids[row["attendance_id"]], member_id=env.ref(f"redimidos18.member_{row['member_id']}").id)
    import_row(model+".line", f"attendance_line_{row['id']}", vals, seen_lines)
env.flush_all()
for name, seen in [(model, seen_headers), (model+".line", seen_lines)]:
    if env[name].with_context(**ctx).search_count([]) != len(seen):
        raise ValueError(f"Registros adicionales en {name}. Se revierte el lote.")
env.cr.commit()
print(f"Asistencias guardadas: {len(seen_headers)}. Líneas verificadas: {len(seen_lines)}.")
PY
