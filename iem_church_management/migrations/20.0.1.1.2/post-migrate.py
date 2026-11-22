from odoo import SUPERUSER_ID, api


def migrate(cr, version):
    env = api.Environment(cr, SUPERUSER_ID, {})
    env["iem.church.weekly.attendance"]._schedule_monthly_attendance_cron()
