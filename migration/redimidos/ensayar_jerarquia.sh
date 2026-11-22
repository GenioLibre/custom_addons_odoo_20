#!/usr/bin/env bash
set -euo pipefail
umask 077
snapshot=$(mktemp)
trap 'rm -f "$snapshot"' EXIT
cd /
runuser -u postgres -- psql -XAtq -v ON_ERROR_STOP=1 -p 5433 -d Redimidos > "$snapshot" <<'SQL'
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;
SELECT json_build_array(
  (SELECT json_agg(row_to_json(p) ORDER BY id) FROM (SELECT id,name,active FROM iem_church_predio) p),
  (SELECT json_agg(row_to_json(r) ORDER BY id) FROM (SELECT id,name,active,predio_id FROM iem_church_red) r),
  (SELECT json_agg(row_to_json(d) ORDER BY id) FROM (SELECT id,name,active,red_id FROM iem_church_discipulado) d),
  (SELECT json_agg(row_to_json(c) ORDER BY id) FROM (SELECT id,name,active,discipulado_id FROM iem_church_celula) c)
);
COMMIT;
SQL
chown odoo20 "$snapshot"
runuser -u odoo20 -- env IEM_SOURCE="$snapshot" /opt/odoo20/venv/bin/python /opt/odoo20/odoo/odoo-bin shell -c /etc/odoo20.conf -d redimidos20_ensayo --db_port=5432 --no-http <<'PY'
import json
import os
from pathlib import Path

if env.cr.dbname != "redimidos20_ensayo":
    raise RuntimeError("Se requiere la base de ensayo")
levels = [
    ("predio", None), ("red", "predio_id"),
    ("discipulado", "red_id"), ("celula", "discipulado_id"),
]
rows_by_level = json.loads(Path(os.environ["IEM_SOURCE"]).read_text())
parents = {}
counts = []
try:
    for (level, relation), rows in zip(levels, rows_by_level, strict=True):
        mapping = {}
        for row in rows or []:
            vals = {key: row[key] for key in ("name", "active")}
            if relation:
                vals[relation] = parents[row[relation]]
            record = env["iem.church." + level].create(vals)
            mapping[row["id"]] = record.id
            if relation and record[relation].id != vals[relation]:
                raise RuntimeError(f"Relación incorrecta en {level} origen {row['id']}")
        parents = mapping
        counts.append((level, len(mapping)))
    env.flush_all()
finally:
    env.cr.rollback()
for level, count in counts:
    print(f"{level}: {count}")
print("Ensayo de jerarquía completado. Cambios revertidos.")
PY
