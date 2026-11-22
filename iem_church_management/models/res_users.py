from odoo import _, models


class ResUsers(models.Model):
    _inherit = "res.users"

    def _notify_security_setting_update(self, subject, content, mail_values=None, **kwargs):
        """Send security update emails with a custom layout without Odoo branding footer."""
        mail_create_values = []
        for user in self:
            renderer = self.env["mail.render.mixin"].with_context(lang=user.lang or self.env.lang or "en_US")
            body_html = renderer._render_template(
                "mail.account_security_alert",
                model="res.users",
                res_ids=user.ids,
                engine="qweb_view",
                options={"post_process": True},
                add_context=user._notify_security_setting_update_prepare_values(content, **kwargs),
            )[user.id]
            body_html = renderer._render_encapsulate(
                "mail.mail_notification_light",
                body_html,
                add_context={"model_description": _("Account")},
                context_record=user,
            )

            vals = {
                "auto_delete": True,
                "body_html": body_html,
                "author_id": self.env.user.partner_id.id,
                "email_from": (
                    user.company_id.partner_id.email_formatted
                    or self.env.user.email_formatted
                    or self.env.ref("base.user_root").email_formatted
                ),
                "email_to": kwargs.get("force_email") or user.email_formatted,
                "subject": subject,
            }

            if mail_values:
                vals.update(mail_values)

            mail_create_values.append(vals)

        return self.env["mail.mail"].sudo().create(mail_create_values)
