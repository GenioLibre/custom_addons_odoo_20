#!/usr/bin/env bash
set -euo pipefail
cd /
umask 077
stage=$(mktemp -d)
trap 'rm -rf -- "$stage"' EXIT
runuser -u postgres -- psql -XAtq -v ON_ERROR_STOP=1 -p 5433 -d Redimidos > "$stage/index.json" <<'SQL'
SELECT json_agg(r ORDER BY id) FROM (
 SELECT id,name,description,public,res_model,res_id,res_field,store_fname,checksum,mimetype,file_size
 FROM ir_attachment WHERE (res_model='iem.church.member.list.line' AND res_field='extra_image')
 OR (res_model='church.member' AND COALESCE(res_field,'')='')
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
expected = {"iem.church.member.list.line":162, "church.member":31}
if Counter(r["res_model"] for r in rows) != expected:
    raise ValueError("El inventario difiere de los 193 adjuntos previstos")
attachments = env["ir.attachment"].sudo().with_context(image_no_postprocess=True, bin_size=False)
used = set()
unlinked_members = 0
for row in rows:
    model_name = row["res_model"]
    field = row["res_field"] or False
    source_id = row["res_id"]
    owner_id = False
    if source_id:
        prefix = "list_line" if field else "member"
        owner = env.ref(f"redimidos18.{prefix}_{source_id}", raise_if_not_found=False)
        if not owner or owner._name != model_name or not owner.exists():
            raise ValueError(f"Falta destino para adjunto {row['id']}, {model_name} origen {source_id}")
        owner_id = owner.id
    elif field or model_name != "church.member":
        raise ValueError(f"Imagen de campo sin registro de origen: adjunto {row['id']}")
    else:
        unlinked_members += 1
    key = f"attachment_{row['id']}"
    rec = env.ref("redimidos18."+key, raise_if_not_found=False)
    if not rec:
        if field and attachments.search_count([("res_model","=",model_name),("res_id","=",owner_id),("res_field","=",field)]):
            raise ValueError(f"El campo ya tiene una imagen sin conciliar: {key}")
        rec = attachments.create({"name":row["name"],"type":"binary","raw":(stage/str(row["id"])).read_bytes(),
                                  "res_model":model_name,"res_id":owner_id,"res_field":field,
                                  "public":bool(row["public"]),"description":row["description"] or False,"mimetype":row["mimetype"]})
        env["ir.model.data"].create({"module":"redimidos18","name":key,"model":"ir.attachment","res_id":rec.id,"noupdate":True})
    if (rec._name != "ir.attachment" or rec.id in used or rec.res_model != model_name or (rec.res_id or False) != owner_id
        or rec.res_field != field or rec.public != bool(row["public"]) or rec.name != row["name"]
        or hashlib.sha1(rec.with_context(bin_size=False).raw or b"").hexdigest() != row["checksum"]):
        raise ValueError(f"Adjunto distinto después de importar: {key}")
    used.add(rec.id)
env.flush_all()
env.cr.commit()
print(f"Adjuntos IEM verificados: 193. Imágenes de listas: 162. De los 31 adjuntos de miembros, {unlinked_members} sin ficha en origen.")
PY
