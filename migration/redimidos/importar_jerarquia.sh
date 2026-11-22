#!/usr/bin/env bash
set -euo pipefail
umask 077
snapshot=$(mktemp)
trap 'rm -f "$snapshot"' EXIT
cd /
runuser -u postgres -- psql -XAtq -v ON_ERROR_STOP=1 -p 5433 -d Redimidos > "$snapshot" <<'SQL'
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;
SELECT json_build_array(
  (SELECT json_agg(row_to_json(p) ORDER BY id) FROM (SELECT org.id,org.name,org.active,org.phone,org.email,country.code AS country_code,state.code AS state_code,state_country.code AS state_country_code,
       org.street,org.street2,org.city,org.zip,org.latitude,org.longitude FROM iem_church_predio org LEFT JOIN res_country country ON country.id=org.country_id
       LEFT JOIN res_country_state state ON state.id=org.state_id
       LEFT JOIN res_country state_country ON state_country.id=state.country_id) p),
  (SELECT json_agg(row_to_json(r) ORDER BY id) FROM (SELECT id,name,active,predio_id FROM iem_church_red) r),
  (SELECT json_agg(row_to_json(d) ORDER BY id) FROM (SELECT id,name,active,red_id FROM iem_church_discipulado) d),
  (SELECT json_agg(row_to_json(c) ORDER BY id) FROM (SELECT org.id,org.name,org.active,org.discipulado_id,country.code AS country_code,state.code AS state_code,state_country.code AS state_country_code,
       org.street,org.street2,org.city,org.zip,org.latitude,org.longitude FROM iem_church_celula org LEFT JOIN res_country country ON country.id=org.country_id
       LEFT JOIN res_country_state state ON state.id=org.state_id
       LEFT JOIN res_country state_country ON state_country.id=state.country_id) c)
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
def lookup(model, domain):
    records = env[model].with_context(active_test=False).search(domain, limit=2)
    if len(records) != 1:
        raise ValueError(f"Referencia geográfica ambigua o ausente en {model}: {domain}")
    return records.id

parents = {}
counts = []
env.cr.execute("SELECT pg_advisory_xact_lock(hashtext('redimidos18_jerarquia'))")
for (level, relation), rows in zip(levels, rows_by_level, strict=True):
    model = "iem.church." + level
    mapping = {}
    for row in rows or []:
        vals = {k: row[k] for k in ("name", "active", "phone", "email", "street", "street2", "city", "zip", "latitude", "longitude") if k in row}
        if relation:
            vals[relation] = parents[row[relation]]
        if "country_code" in row:
            vals["country_id"] = lookup("res.country", [("code", "=", row["country_code"])]) if row["country_code"] else False
            vals["state_id"] = lookup("res.country.state", [("country_id.code", "=", row["state_country_code"]), ("code", "=", row["state_code"])]) if row["state_code"] else False
        key = f"{level}_{row['id']}"
        xmlid = "redimidos18." + key
        rec = env.ref(xmlid, raise_if_not_found=False)
        if rec:
            if rec._name != model:
                raise ValueError(f"Modelo incorrecto para {xmlid}")
            for field, value in vals.items():
                current = rec[field]
                if rec._fields[field].type == "many2one":
                    current = current.id
                if (current or False) != (value or False):
                    raise ValueError(f"Diferencia en {xmlid}, campo {field}")
        else:
            rec = env[model].create(vals)
            env["ir.model.data"].create({"module": "redimidos18", "name": key, "model": model, "res_id": rec.id, "noupdate": True})
        mapping[row["id"]] = rec.id
    parents = mapping
    counts.append(len(mapping))
if counts != [1, 2, 6, 34]:
    raise ValueError(f"Los conteos difieren del ensayo: {counts}")
env.flush_all()
env.cr.commit()
print("Jerarquía guardada: 1 predio, 2 redes, 6 discipulados y 34 células.")
PY
