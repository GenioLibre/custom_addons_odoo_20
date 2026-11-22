#!/usr/bin/env bash
set -euo pipefail
cd /
umask 077
source_ids=$(mktemp)
trap 'rm -f "$source_ids"' EXIT
runuser -u postgres -- psql -XAtq -v ON_ERROR_STOP=1 -p 5433 -d Redimidos > "$source_ids" <<'SQL'
SELECT json_build_array(
 (SELECT json_agg(t ORDER BY id) FROM (SELECT id,name,sequence,active FROM iem_financial_contribution_type) t),
 (SELECT json_agg(p ORDER BY id) FROM (SELECT id,name,sequence,active FROM iem_financial_payment_method) p),
 (SELECT json_agg(c ORDER BY id) FROM (SELECT f.id,f.name,f.member_id,f.predio_id,f.red_id,f.discipulado_id,
 f.registration_date,f.contribution_type_id,f.contribution_month,f.contribution_year,r.name AS currency,
 f.amount::text AS amount,f.state,f.payment_method_id,f.reference,f.note
 FROM iem_financial_contribution f LEFT JOIN res_currency r ON r.id=f.currency_id) c)
);
SQL
chown odoo20 "$source_ids"
runuser -u odoo20 -- env IEM_SOURCE="$source_ids" /opt/odoo20/venv/bin/python /opt/odoo20/odoo/odoo-bin shell -c /etc/odoo20.conf -d redimidos20_ensayo --db_port=5432 --no-http <<'PY'
import json
import os
from pathlib import Path

if env.cr.dbname != "redimidos20_ensayo":
    raise ValueError("Destino inesperado")
env.cr.execute("SELECT pg_advisory_xact_lock(hashtext('redimidos18_aportes'))")
rows = json.loads(Path(os.environ["IEM_SOURCE"]).read_text())
from datetime import date
from decimal import Decimal

types, methods, contributions = (part or [] for part in rows)
if (len(types), len(methods), len(contributions)) != (1, 0, 1):
    raise ValueError("El origen difiere del inventario del ensayo")
def save(model, key, vals):
    target = env[model].with_context(active_test=False, tracking_disable=True, mail_create_nosubscribe=True)
    rec = env.ref("redimidos18." + key, raise_if_not_found=False)
    if not rec:
        rec = target.create(dict(vals))
        env["ir.model.data"].create({"module":"redimidos18","name":key,"model":model,"res_id":rec.id,"noupdate":True})
    if rec._name != model or not rec.exists():
        raise ValueError(f"Referencia incorrecta: {key}")
    for field, expected in vals.items():
        actual = rec[field]
        if rec._fields[field].type == "many2one":
            actual = actual.id
        if field == "amount":
            actual, expected = Decimal(str(actual)), Decimal(str(expected))
        if actual != expected:
            raise ValueError(f"Diferencia en {key}: {field}")
    return rec
for row in types:
    save("iem.financial.contribution.type", f"contribution_type_{row['id']}", {k:row[k] for k in ("name","sequence","active")})
for row in contributions:
    cur = env["res.currency"].with_context(active_test=False).search([("name","=",row["currency"])],limit=2)
    if len(cur) != 1:
        raise ValueError("Moneda de origen sin coincidencia única")
    vals = {k:row[k] or False for k in ("name","state","reference","note","contribution_month")}
    vals.update(currency_id=cur.id, amount=Decimal(row["amount"]), registration_date=date.fromisoformat(row["registration_date"]) if row["registration_date"] else False, contribution_year=row["contribution_year"] or 0, payment_method_id=False)
    for field in ("member","predio","red","discipulado","contribution_type"):
        sid = row[field+"_id"]
        vals[field+"_id"] = env.ref(f"redimidos18.{field}_{sid}").id if sid else False
    save("iem.financial.contribution", f"contribution_{row['id']}", vals)
env.flush_all()
for model, count in [("iem.financial.contribution",1), ("iem.financial.contribution.type",1), ("iem.financial.payment.method",0)]:
    if env[model].with_context(active_test=False).search_count([]) != count:
        raise ValueError(f"Conteo inesperado en {model}")
env.cr.commit()
print("Aporte guardado: 1. Importe, moneda y vínculos verificados.")
PY
