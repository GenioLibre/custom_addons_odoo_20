#!/usr/bin/env bash
set -euo pipefail
umask 077
scripts=$(cd "$(dirname "$0")" && pwd)
cd /
stage=$(mktemp -d)
trap 'rm -rf -- "$stage"' EXIT
runuser -u postgres -- psql -XAtq -v ON_ERROR_STOP=1 -p 5433 -d Redimidos > "$stage/source" <<'SQL'
SELECT json_build_object(
'users',(SELECT json_agg(json_build_object('id',id,'active',active,'share',share,'password',password,'mfa',NULLIF(to_jsonb(u)->>'totp_secret','') IS NOT NULL,'groups',ARRAY(SELECT gid FROM res_groups_users_rel WHERE uid=u.id))) FROM res_users u),
'groups',(SELECT json_object_agg(id,ARRAY(SELECT module||'.'||name FROM ir_model_data WHERE model='res.groups' AND res_id=g.id)) FROM res_groups g),
'params',(SELECT json_object_agg(key,value) FROM ir_config_parameter WHERE key LIKE 'iem.%'),
'sites',(SELECT json_agg(json_build_object('id',id,'name',name,'homepage_url',homepage_url)) FROM website),
'pages',(SELECT json_agg(json_build_object('id',p.id,'view',v.id,'site',v.website_id,'active',v.active,'xmlids',ARRAY(SELECT d.module||'.'||d.name FROM ir_model_data d WHERE d.model='website.page' AND d.res_id=p.id),'arch',v.arch_db,'key',v.key,'url',p.url,'name',v.name,'published',p.is_published,'indexed',p.website_indexed,'visibility',to_jsonb(v)->>'visibility','password',to_jsonb(v)->>'visibility_password','groups',ARRAY(SELECT group_id FROM ir_ui_view_group_rel WHERE view_id=v.id))) FROM website_page p JOIN ir_ui_view v ON v.id=p.view_id),
'menus',(SELECT json_agg(to_jsonb(m) || jsonb_build_object('groups',ARRAY(SELECT res_groups_id FROM res_groups_website_menu_rel WHERE website_menu_id=m.id)) ORDER BY id) FROM website_menu m WHERE website_id IS NOT NULL),
'files',(SELECT json_agg(json_build_object('id',id,'model',res_model,'owner',res_id,'field',res_field,'name',name,'path',store_fname,'sha',checksum,'mime',mimetype,'public',public,'url',url,'type',type,'description',description,'standard',EXISTS(SELECT 1 FROM ir_model_data d WHERE d.model='ir.attachment' AND d.res_id=f.id AND d.module NOT IN ('__export__','iem_church_management')))) FROM ir_attachment f)
);
SQL
python3 - "$stage" <<'PY'
import hashlib, json, re, sys
from pathlib import Path
stage = Path(sys.argv[1])
root = Path("/var/lib/odoo-migracion/filestore/Redimidos").resolve(strict=True)
data = json.loads((stage/"source").read_text())
for row in data["files"]:
    if row["model"] not in (None,"ir.ui.view","website","res.config.settings","ir.attachment") or not row["path"]:
        continue
    name = row["path"]
    if not re.fullmatch(r"[0-9a-f]{2}/[0-9a-f]{40}",name):
        raise ValueError("Ruta de filestore inválida")
    src = (root/name).resolve(strict=True)
    if not src.is_relative_to(root):
        raise ValueError("Ruta fuera del filestore")
    raw = src.read_bytes()
    if hashlib.sha1(raw).hexdigest()!=row["sha"]:
        raise ValueError(f"Huella distinta: adjunto {row['id']}")
    (stage/str(row["id"])).write_bytes(raw)
PY
chown -R odoo20 "$stage"
runuser -u odoo20 -- env IEM_STAGE="$stage" /opt/odoo20/venv/bin/python /opt/odoo20/odoo/odoo-bin shell -c /etc/odoo20.conf -d redimidos20_ensayo --db_port=5432 --no-http < "$scripts/seleccion_final.py"
