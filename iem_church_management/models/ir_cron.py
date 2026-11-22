from odoo import models


class IrCron(models.Model):
    _inherit = "ir.cron"

    def method_direct_trigger(self):
        self.ensure_one()
        monthly_cron = self.env.ref(
            "iem_church_management.cron_church_email_monthly_attendance",
            raise_if_not_found=False,
        )
        if self != monthly_cron:
            return super().method_direct_trigger()

        self.check_access("write")
        attendance = self.env["iem.church.weekly.attendance"].with_user(self.user_id)
        attendance._cron_email_monthly_attendance(manual=True)
        return True
