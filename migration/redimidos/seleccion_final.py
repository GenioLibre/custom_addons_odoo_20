"""Run only through importar_seleccion_final.sh in the CT 130 rehearsal."""
import hashlib
import json
import os
import re
from pathlib import Path
from lxml import etree

stage = Path(os.environ["IEM_STAGE"])
src = json.loads((stage / "source").read_text())
if env.cr.dbname != "redimidos20_ensayo":
    raise ValueError("Destino inesperado")
env.cr.execute("SELECT pg_advisory_xact_lock(hashtext('redimidos18_final'))")
ctx = dict(active_test=False,tracking_disable=True,no_reset_password=True,mail_create_nosubscribe=True)
def model(name):
    return env[name].sudo().with_context(**ctx)

def ref(key):
    return env.ref("redimidos18."+key,raise_if_not_found=False)

def mark(key, rec):
    old = ref(key)
    if old and old != rec:
        raise ValueError(f"Vínculo contradictorio: {key}")
    if not old:
        model("ir.model.data").create(dict(module="redimidos18",name=key,model=rec._name,res_id=rec.id,noupdate=True))

def single(recs, label):
    if len(recs)!=1:
        raise ValueError(f"Se esperaba una coincidencia: {label}")
    return recs

def translations(value):
    return value if isinstance(value,dict) else {"en_US":value}

def label(value):
    values = translations(value)
    return values.get("en_US") or next(iter(values.values()))

groups = {}
missing = []
group_ids = set()
for row in src["users"] + (src["menus"] or []) + src["pages"]:
    group_ids.update(row["groups"])
for gid in sorted(group_ids):
    ids = src["groups"][str(gid)]
    matches = {r.id for xid in ids if (r:=env.ref(xid,raise_if_not_found=False)) and r._name=="res.groups"}
    if len(matches)!=1:
        missing.append("/".join(ids) or f"grupo de origen {gid}")
    else:
        groups[gid] = matches.pop()
if missing:
    raise ValueError("Grupos que requieren equivalencia en Odoo 20: "+", ".join(missing))
site = single(model("website").search([]),"sitio destino")
site_src, = src["sites"]
files = {r["id"]:r for r in src["files"]}
views = {}
pages = {}
for row in src["pages"]:
    urls = translations(row["url"])
    page = ref(f"page_{row['id']}") or model("website.page").search([("website_id","=",site.id),("url","=",label(urls))],limit=2)
    if not page:
        view = model("ir.ui.view").create({"name":label(row["name"]),"key":row["key"],"type":"qweb","website_id":site.id,"arch_db":"<t/>"})
        page = model("website.page").create({"view_id":view.id,"url":label(urls),"is_published":False})
    single(page,"página")
    if page.id in [p.id for p in pages.values()]:
        raise ValueError("Dos páginas apuntan al mismo destino")
    pages[row["id"]] = page
    views[row["view"]] = page.view_id
    mark(f"page_{row['id']}",page)

# Numeric Odoo attachment URLs in HTML, CSS and menu links.
pat = re.compile(r"(/web/(?:image|content)/(?:(?:ir\.attachment)/)?)(\d+)(?:-[0-9a-fA-F]{6,64})?(?=[/?#\s\"')<]|$)")
logo = int((src["params"] or {}).get("iem.church_logo_attachment_id") or 0)
mapped = {}
def attach(sid):
    if sid in mapped:
        return mapped[sid]
    r = files.get(sid)
    if not r:
        raise ValueError(f"Referencia web a archivo inexistente: {sid}")
    old = ref(f"attachment_{sid}")
    if old:
        mapped[sid]=old
        return old
    if r["model"]=="website" and r["owner"]==site_src["id"]:
        owner=site
    elif r["model"]=="ir.ui.view" and r["owner"] in views:
        owner=views[r["owner"]]
    elif sid==logo and r["model"]=="res.config.settings":
        owner=model("res.config.settings")
    elif not r["model"] and not r["owner"]:
        owner=None
    else:
        raise ValueError(f"Archivo web {sid}: falta conciliar propietario de tipo {r['model']}")
    vals=dict(name=r["name"],description=r["description"] or False,public=bool(r["public"]),type=r["type"],
              res_model=owner._name if owner is not None else False,res_id=owner.id if owner else False,res_field=r["field"] or False)
    if r["type"]=="binary":
        vals.update(raw=(stage/str(sid)).read_bytes(),mimetype=r["mime"])
    else:
        vals["url"]=r["url"]
    atts=model("ir.attachment").with_context(image_no_postprocess=True)
    rec=None
    if owner and r["field"]:
        rec=atts.search([("res_model","=",owner._name),("res_id","=",owner.id),("res_field","=",r["field"])],limit=2)
    if rec:
        single(rec,"imagen del sitio").write(vals)
    else:
        rec=atts.create(vals)
    if r["type"]=="binary" and rec.checksum!=r["sha"]:
        raise ValueError(f"Archivo {sid}: checksum distinto")
    mark(f"attachment_{sid}",rec)
    mapped[sid]=rec
    return rec

def rewrite(value):
    return pat.sub(lambda m:m[1]+str(attach(int(m[2])).id),value) if value else value

def translated(rec, field, value, transform=lambda x:x):
    for lang,text in translations(value).items():
        if text is not None:
            if not model("res.lang").search_count([("code","=",lang),("active","=",True)]):
                env["res.lang"]._activate_lang(lang)
            rec.with_context(lang=lang).write({field:transform(text)})

for r in files.values():
    if r["id"]==logo or (r["model"]=="website" and r["owner"]==site_src["id"] and not r["standard"]) or (r["model"]=="ir.ui.view" and r["owner"] in views and not r["standard"]):
        attach(r["id"])
for row in src["pages"]:
    p=pages[row["id"]]
    v=p.view_id
    translated(v,"arch_db",row["arch"],rewrite)
    translated(v,"name",row["name"])
    translated(p,"url",row["url"])
    v.write({"visibility":row["visibility"] or False,"visibility_password":row["password"] or False,"group_ids":[(6,0,[groups[g] for g in row["groups"]])]})
    p.write({"website_indexed":row["indexed"],"is_published":row["published"]})
    etree.fromstring(v.arch_db.encode())
translated(site,"name",site_src["name"])
site.write({"homepage_url":site_src["homepage_url"] or "/"})
menu_map={}
pending=list(src["menus"] or [])
while pending:
    ready=[r for r in pending if not r["parent_id"] or r["parent_id"] in menu_map]
    if not ready:
        raise ValueError("Menú sin padre mapeado")
    for r in ready:
        pending.remove(r)
        parent=menu_map.get(r["parent_id"])
        if not parent:
            menu=site.menu_id
            single(menu,"menú principal")
        else:
            menu=ref(f"menu_{r['id']}")
            if not menu:
                menu=model("website.menu").search([("parent_id","=",parent.id),("name","=",label(r["name"]))],limit=2)
            if not menu:
                menu=model("website.menu").create({"name":label(r["name"]),"parent_id":parent.id,"website_id":site.id})
            single(menu,"menú")
        if menu.id in [x.id for x in menu_map.values()]:
            raise ValueError("Dos menús con el mismo destino")
        if r.get("controller_page_id"):
            raise ValueError("Página de controlador sin equivalencia")
        vals={"sequence":r["sequence"],"new_window":r["new_window"],"group_ids":[(6,0,[groups[g] for g in r["groups"]])]}
        if parent:
            vals["page_id"]=pages[r["page_id"]].id if r["page_id"] else False
            vals["manual_url"]=rewrite(r["url"]) if r["url"] else False
        menu.write(vals)
        translated(menu,"name",r["name"])
        if r.get("mega_menu_content"):
            translated(menu,"mega_menu_content",r["mega_menu_content"],rewrite)
        mark(f"menu_{r['id']}",menu)
        menu_map[r["id"]]=menu

cfg=model("ir.config_parameter")
for key,value in (src["params"] or {}).items():
    if key=="iem.church_logo_attachment_id":
        cfg.set_int(key,attach(logo).id if logo else 0)
    elif key=="iem.public_member_form_rate_limit":
        cfg.set_int(key,int(value or 0))
    elif key in ("iem.dni_api_token","iem.public_member_form_password","iem.church_logo_filename","iem.church_logo_mimetype"):
        cfg.set_str(key,value or "")
    else:
        raise ValueError(f"Ajuste IEM sin equivalencia: {key}")

for r in src["users"]:
    u=ref(f"user_{r['id']}")
    if not u or u._name!="res.users":
        raise ValueError(f"Usuario sin correspondencia: {r['id']}")
    if r["mfa"] and r["active"]:
        raise ValueError(f"Requiere migración de segundo factor: usuario origen {r['id']}")
    if u.id==env.ref("base.user_root").id:
        continue
    chosen={groups[g] for g in r["groups"]}
    u.with_context(**ctx).write({"group_ids":[(6,0,sorted(chosen))],"active":r["active"]})
    if set(u.group_ids.ids)!=chosen or u.active!=r["active"] or u.share!=r["share"]:
        raise ValueError(f"Discrepancia de permisos en usuario origen {r['id']}")
    if u!=env.ref("base.user_admin") and r["password"]:
        if not r["password"].startswith("$pbkdf2-sha512$"):
            raise ValueError(f"Formato de contraseña pendiente: usuario origen {r['id']}")
        env.cr.execute("UPDATE res_users SET password=%s WHERE id=%s",(r["password"],u.id))
env.flush_all()
env.cr.commit()
print(f"Lote guardado. Usuarios revisados: {len(src['users'])}. Páginas: {len(pages)}. Menús: {len(menu_map)}. Archivos web/IEM conciliados en este lote: {len(mapped)}.")
