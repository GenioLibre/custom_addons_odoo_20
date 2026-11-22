#!/usr/bin/env bash
set -euo pipefail
cd /
umask 077
stage=$(mktemp -d)
trap 'rm -rf -- "$stage"' EXIT
runuser -u postgres -- psql -XAtq -v ON_ERROR_STOP=1 -p 5433 -d Redimidos > "$stage/index.json" <<'SQL'
SELECT json_agg(r ORDER BY id) FROM (
 SELECT id,name,description,public,res_model,res_id,res_field,store_fname,checksum,mimetype,file_size
 FROM ir_attachment WHERE res_model='res.partner'
 AND res_field IN ('image_1920','image_1024','image_512','image_256','image_128')
) r;
SQL
python3 - "$stage" <<'PY'
import hashlib, json, re, shutil, sys
from pathlib import Path
stage = Path(sys.argv[1])
root = Path("/var/lib/odoo-migracion/filestore/Redimidos").resolve(strict=True)
rows = json.loads((stage/"index.json").read_text())
for row in rows:
    name = row["store_fname"] or ""
    if not re.fullmatch(r"[0-9a-f]{2}/[0-9a-f]{40}", name):
        raise ValueError(f"Ruta inesperada en adjunto {row['id']}")
    path = (root/name).resolve(strict=True)
    if not path.is_relative_to(root):
        raise ValueError("Archivo fuera del filestore")
    out = stage/str(int(row["id"]))
    shutil.copyfile(path,out)
    if out.stat().st_size != row["file_size"] or hashlib.sha1(out.read_bytes()).hexdigest() != row["checksum"]:
        raise ValueError(f"Archivo distinto del inventario: {row['id']}")
PY
chown -R odoo20 "$stage"
runuser -u odoo20 -- env IEM_STAGE="$stage" /opt/odoo20/venv/bin/python /opt/odoo20/odoo/odoo-bin shell -c /etc/odoo20.conf -d redimidos20_ensayo --db_port=5432 --no-http <<'PY'
import hashlib, json, os
from collections import Counter
from pathlib import Path

if env.cr.dbname != "redimidos20_ensayo":
    raise ValueError("Destino inesperado")
env.cr.execute("SELECT pg_advisory_xact_lock(hashtext('redimidos18_adjuntos'))")
stage = Path(os.environ["IEM_STAGE"])
rows = json.loads((stage/"index.json").read_text())
fields = {f"image_{size}" for size in (1920,1024,512,256,128)}
pairs = {(r["res_id"],r["res_field"]) for r in rows}
owners = {r["res_id"] for r in rows}
if None in owners or len(owners)!=38 or len(rows)!=190 or pairs != {(sid,f) for sid in owners for f in fields}:
    raise ValueError("Las cinco variantes no corresponden a los mismos 38 contactos. Se requiere conciliación.")
attachments = env["ir.attachment"].sudo().with_context(image_no_postprocess=True, bin_size=False)
used = set()
checks = []
for row in rows:
    field = row["res_field"]
    partner = env.ref(f"redimidos18.partner_{row['res_id']}")
    if partner._name != "res.partner" or not partner.exists() or not getattr(partner._fields.get(field),"attachment",False):
        raise ValueError(f"Destino incompatible para adjunto {row['id']}, campo {field}")
    existing = attachments.search([("res_model","=","res.partner"),("res_id","=",partner.id),("res_field","=",field)],limit=2)
    key = f"attachment_{row['id']}"
    mapped = env.ref("redimidos18."+key,raise_if_not_found=False)
    if len(existing)>1 or (mapped and mapped != existing):
        raise ValueError(f"Vínculo ambiguo para {key}")
    vals = {"name":row["name"],"description":row["description"] or False,"public":bool(row["public"]),
            "mimetype":row["mimetype"],"raw":(stage/str(row["id"])).read_bytes()}
    if not existing:
        rec = attachments.create(dict(vals,res_model="res.partner",res_id=partner.id,res_field=field))
    else:
        rec = existing
        if not mapped:
            rec.write(vals)
    if not mapped:
        env["ir.model.data"].create({"module":"redimidos18","name":key,"model":"ir.attachment","res_id":rec.id,"noupdate":True})
    if rec.id in used or rec.public != bool(row["public"]) or rec.checksum != row["checksum"]:
        raise ValueError(f"Foto o visibilidad distinta para {key}")
    used.add(rec.id)
    checks.append((partner,field,row["checksum"]))
env.flush_all()
for partner,field,digest in checks:
    partner.invalidate_recordset([field])
    data = partner.with_context(bin_size=False)[field]
    if not data or hashlib.sha1(data.content).hexdigest()!=digest:
        raise ValueError(f"El contacto destino {partner.id} no devuelve la imagen histórica en {field}")
env.cr.commit()
print("Fotos verificadas: 38 contactos, 190 imágenes en cinco tamaños.")
PY
