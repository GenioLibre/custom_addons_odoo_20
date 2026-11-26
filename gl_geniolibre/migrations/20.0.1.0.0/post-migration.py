from odoo import SUPERUSER_ID, api


def migrate(cr, version):
    env = api.Environment(cr, SUPERUSER_ID, {})
    privilege = env.ref('gl_geniolibre.privilege_project_task')
    for role, sequence in (('user', 10), ('admin', 20)):
        group = env.ref(f'gl_geniolibre.group_project_task_{role}')
        group.write({'privilege_id': privilege.id, 'sequence': sequence})
