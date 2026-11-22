#!/usr/bin/env bash
set -euo pipefail
cd /
umask 077
source_ids=$(mktemp)
trap 'rm -f "$source_ids"' EXIT
runuser -u postgres -- psql -XAtq -v ON_ERROR_STOP=1 -p 5433 -d Redimidos > "$source_ids" <<'SQL'
SELECT json_agg(r ORDER BY id) FROM (
 SELECT u.id,u.login,u.partner_id,ARRAY(SELECT d.module || '.' || d.name
 FROM ir_model_data d WHERE d.model='res.users' AND d.res_id=u.id ORDER BY d.module,d.name) AS xmlids
 FROM res_users u
) r;
SQL
chown odoo20 "$source_ids"
runuser -u odoo20 -- env IEM_SOURCE="$source_ids" /opt/odoo20/venv/bin/python /opt/odoo20/odoo/odoo-bin shell -c /etc/odoo20.conf -d redimidos20_ensayo --db_port=5432 --no-http <<'PY'
import json
import os
from pathlib import Path

if env.cr.dbname != "redimidos20_ensayo":
    raise ValueError("Destino inesperado")
env.cr.execute("SELECT pg_advisory_xact_lock(hashtext('redimidos18_usuarios'))")
rows = json.loads(Path(os.environ["IEM_SOURCE"]).read_text())
users = env["res.users"].with_context(active_test=False, no_reset_password=True, tracking_disable=True, mail_create_nosubscribe=True)
seen = set()
created = 0
for row in rows:
    key = f"user_{row['id']}"
    mapping = "redimidos18." + key
    partner = env.ref(f"redimidos18.partner_{row['partner_id']}")
    candidates = users.search([("login","=",row["login"])]) | users.search([("partner_id","=",partner.id)])
    for xmlid in [mapping, *row["xmlids"]]:
        existing = env.ref(xmlid, raise_if_not_found=False)
        if existing:
            if existing._name != "res.users" or not existing.exists():
                raise ValueError(f"Referencia incompatible: {key}")
            candidates |= existing
    if len(candidates) > 1:
        raise ValueError(f"Más de una cuenta candidata para {key}")
    if candidates:
        rec = candidates
    else:
        rec = users.create({"partner_id":partner.id,"login":row["login"],
                            "group_ids":[(6,0,[])],"company_id":env.company.id,
                            "company_ids":[(6,0,[env.company.id])]})
        rec.write({"active":False})
        if rec.active:
            raise ValueError(f"La cuenta nueva debería estar archivada: {key}")
        created += 1
    if rec.partner_id != partner or rec.id in seen:
        raise ValueError(f"Contacto o identidad incompatible: {key}")
    seen.add(rec.id)
    if not env.ref(mapping, raise_if_not_found=False):
        env["ir.model.data"].create({"module":"redimidos18","name":key,"model":"res.users","res_id":rec.id,"noupdate":True})
if len(seen) != 13:
    raise ValueError("Conteo distinto del inventario de 13 usuarios")
env.flush_all()
env.cr.commit()
print(f"Usuarios vinculados: {len(seen)}. Reutilizados: {len(seen)-created}. Nuevos archivados: {created}.")
PY
