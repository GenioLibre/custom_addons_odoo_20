#!/usr/bin/env bash
set -euo pipefail
cd /
umask 077
source_ids=$(mktemp)
trap 'rm -f "$source_ids"' EXIT
runuser -u postgres -- psql -XAtq -v ON_ERROR_STOP=1 -p 5433 -d Redimidos > "$source_ids" <<'SQL'
SELECT json_agg(entry ORDER BY id)
FROM (
    SELECT p.id, ARRAY(
        SELECT d.module || '.' || d.name FROM ir_model_data d
        WHERE d.model = 'res.partner' AND d.res_id = p.id ORDER BY d.module, d.name
    ) AS xmlids
    FROM res_partner p
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
seen = {}
for row in rows:
    key = f"partner_{row['id']}"
    mapping = "redimidos18." + key
    candidates = set()
    for xmlid in [mapping, *row["xmlids"]]:
        rec = env.ref(xmlid, raise_if_not_found=False)
        if rec and rec.exists():
            if rec._name != "res.partner":
                raise ValueError(f"Modelo incompatible para contacto de origen {row['id']}")
            candidates.add(rec.id)
    if not candidates:
        continue
    if len(candidates) != 1:
        raise ValueError(f"Referencias contradictorias para contacto de origen {row['id']}")
    target = candidates.pop()
    if target in seen:
        raise ValueError(f"Contactos de origen {row['id']} y {seen[target]} coinciden en destino")
    seen[target] = row["id"]
    if not env.ref(mapping, raise_if_not_found=False):
        env["ir.model.data"].create({"module": "redimidos18", "name": key, "model": "res.partner", "res_id": target, "noupdate": True})
env.cr.commit()
print(f"Contactos de origen: {len(rows)}")
print(f"Vinculados por identificador externo: {len(seen)}")
print(f"Pendientes de conciliar o crear: {len(rows) - len(seen)}")
PY
