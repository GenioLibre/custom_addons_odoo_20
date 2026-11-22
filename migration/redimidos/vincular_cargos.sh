#!/usr/bin/env bash
set -euo pipefail
cd /
umask 077
source_ids=$(mktemp)
trap 'rm -f "$source_ids"' EXIT
runuser -u postgres -- psql -XAtq -v ON_ERROR_STOP=1 -p 5433 -d Redimidos > "$source_ids" <<'SQL'
SELECT json_agg(r ORDER BY id) FROM (SELECT id,name,code,sequence,active FROM iem_church_member_position_option) r;
SQL
chown odoo20 "$source_ids"
runuser -u odoo20 -- env IEM_SOURCE="$source_ids" /opt/odoo20/venv/bin/python /opt/odoo20/odoo/odoo-bin shell -c /etc/odoo20.conf -d redimidos20_ensayo --db_port=5432 --no-http <<'PY'
import json
import os
from pathlib import Path

if env.cr.dbname != "redimidos20_ensayo":
    raise ValueError("Destino inesperado")
env.cr.execute("SELECT pg_advisory_xact_lock(hashtext('redimidos18_cargos'))")
rows = json.loads(Path(os.environ["IEM_SOURCE"]).read_text())
model = "iem.church.member.position.option"
options = env[model].with_context(active_test=False)
seen = set()
for row in rows:
    key = f"position_{row['id']}"
    mapped = env.ref("redimidos18." + key, raise_if_not_found=False)
    rec = options.search([("code","=",row["code"])], limit=2)
    if len(rec) > 1 or (mapped and mapped != rec):
        raise ValueError(f"Código ambiguo o vínculo incompatible: {key}")
    vals = {field:row[field] for field in ("name","code","sequence","active")}
    if not rec:
        rec = options.create(vals)
    if rec.id in seen:
        raise ValueError(f"Cargo repetido en origen: {key}")
    seen.add(rec.id)
    changes = {field:value for field,value in vals.items() if rec[field] != value}
    if changes:
        rec.write(changes)
    if not mapped:
        env["ir.model.data"].create({"module":"redimidos18","name":key,"model":model,"res_id":rec.id,"noupdate":True})
    if any(rec[field] != value for field,value in vals.items()):
        raise ValueError(f"Diferencia en el cargo {key}")
if len(seen) != 9:
    raise ValueError("Conteo de cargos distinto al del inventario")
env.flush_all()
env.cr.commit()
print(f"Cargos vinculados y verificados: {len(seen)}.")
PY
