from odoo import SUPERUSER_ID, api


def migrate(cr, version):
    env = api.Environment(cr, SUPERUSER_ID, {})
    administrator = env.ref("base.user_admin").partner_id
    dispatches = env["iem.church.monthly.dispatch"].search([
        ("mail_id.state", "in", ["outgoing", "exception"]),
        ("mail_id.mail_message_id.create_uid", "=", SUPERUSER_ID),
    ])
    messages = dispatches.mail_id.mail_message_id
    messages.filtered(lambda message: message.author_id != administrator).write({
        "author_id": administrator.id,
    })
