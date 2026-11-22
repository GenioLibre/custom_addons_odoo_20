#!/usr/bin/env bash
set -euo pipefail
cd /
umask 077
source_ids=$(mktemp)
trap 'rm -f "$source_ids"' EXIT
runuser -u postgres -- psql -XAtq -v ON_ERROR_STOP=1 -p 5433 -d Redimidos > "$source_ids" <<'SQL'
SELECT json_agg(r ORDER BY level,id) FROM (
 SELECT 'predio' AS level,id,pastor_id AS partner FROM iem_church_predio
 UNION ALL SELECT 'red',id,pastor_id FROM iem_church_red
 UNION ALL SELECT 'discipulado',id,discipulador_id FROM iem_church_discipulado
 UNION ALL SELECT 'celula',id,lider_id FROM iem_church_celula
) r;
SQL
chown odoo20 "$source_ids"
runuser -u odoo20 -- env IEM_SOURCE="$source_ids" /opt/odoo20/venv/bin/python /opt/odoo20/odoo/odoo-bin shell -c /etc/odoo20.conf -d redimidos20_ensayo --db_port=5432 --no-http <<'PY'
import json
import os
from pathlib import Path

if env.cr.dbname != "redimidos20_ensayo":
    raise ValueError("Destino inesperado")
env.cr.execute("SELECT pg_advisory_xact_lock(hashtext('redimidos18_responsables'))")
rows = json.loads(Path(os.environ["IEM_SOURCE"]).read_text())
from collections import Counter
fields_by_level = {"predio":"pastor_id","red":"pastor_id","discipulado":"discipulador_id","celula":"lider_id"}
if Counter(row["level"] for row in rows) != {"predio":1,"red":2,"discipulado":6,"celula":34}:
    raise ValueError("Inventario de unidades inesperado")
assigned = 0
for row in rows:
    level = row["level"]
    unit = env.ref(f"redimidos18.{level}_{row['id']}")
    partner = env.ref(f"redimidos18.partner_{row['partner']}") if row["partner"] else env["res.partner"]
    if unit._name != "iem.church." + level or not unit.exists() or partner._name != "res.partner" or (partner and not partner.exists()):
        raise ValueError(f"Referencia incompatible: {level} {row['id']}")
    field = fields_by_level[level]
    if unit[field] and unit[field] != partner:
        raise ValueError(f"Responsable distinto en destino: {level} {row['id']}")
    if unit[field] != partner:
        unit.with_context(tracking_disable=True).write({field:partner.id})
    if unit[field] != partner:
        raise ValueError(f"Error al vincular {level} {row['id']}")
    assigned += bool(partner)
env.flush_all()
env.cr.commit()
print(f"Unidades verificadas: {len(rows)}. Con responsable: {assigned}. Sin responsable en origen: {len(rows)-assigned}.")
PY
