import logging
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

from dateutil.relativedelta import relativedelta
from markupsafe import Markup

from odoo import _, api, fields, models

_logger = logging.getLogger(__name__)
_REPORT_TIMEZONE = ZoneInfo("America/Lima")


class ChurchMonthlyAttendance(models.Model):
    _inherit = "iem.church.weekly.attendance"

    @api.model
    def _report_today(self):
        return datetime.now(_REPORT_TIMEZONE).date()

    @api.model
    def _monthly_rows(self, cells, month, today):
        month = month.replace(day=1)
        next_month = month + relativedelta(months=1)
        cutoff = min(today, next_month)
        rolling_start = cutoff - timedelta(days=30)
        first_relevant = min(month, rolling_start)

        weeks_by_cell = defaultdict(dict)
        weeks = self.search([
            ("celula_id", "in", cells.ids), ("week_end", ">=", first_relevant),
            ("week_end", "<", cutoff),
        ])
        for week in weeks:
            weeks_by_cell[week.celula_id.id][week.week_end] = week

        contact_counts = defaultdict(int)
        consolidation_counts = defaultdict(int)
        followups = self.env["iem.church.cell.followup"].search([
            ("celula_id", "in", cells.ids), ("state", "in", ["pending", "contacted"]),
        ])
        for case in followups:
            if case.kind == "absence" and case.state == "pending":
                contact_counts[case.celula_id.id] += 1
            elif case.kind == "guest":
                deadline = case.next_contact or case.guest_since + timedelta(days=7)
                if deadline <= today:
                    consolidation_counts[case.celula_id.id] += 1

        rows = []
        for cell in cells:
            cell_weeks = weeks_by_cell[cell.id]
            started = cell.create_date.date() if cell.create_date else month
            if cell_weeks:
                started = min(started, min(week.week_start for week in cell_weeks.values()))
            month_weeks = [week for end, week in cell_weeks.items() if end >= month]
            held = [week for week in month_weeks if week.meeting_state == "held"]
            historical = [week for week in month_weeks if week.meeting_state == "legacy"]
            counted = held + [week for week in historical if week.total_attended_celula]
            cancelled = sum(week.meeting_state == "cancelled" for week in month_weeks)
            present = {line.member_id.id for week in counted for line in week.line_ids if line.attended_celula}
            guests = sum(week.guest_count for week in counted if week.guest_count_known)
            guest_weeks = sum(week.guest_count_known for week in counted)
            pending = sum(
                week_end not in cell_weeks or cell_weeks[week_end].meeting_state == "draft"
                for week_end in self._closed_week_ends(max(started, month), cutoff)
            )
            rolling = [
                cell_weeks.get(week_end)
                for week_end in self._closed_week_ends(max(started, rolling_start), cutoff)
            ]
            no_guests = (
                started <= rolling_start
                and any(week and week.meeting_state == "held" for week in rolling)
                and all(week and (
                    week.meeting_state == "cancelled"
                    or (week.meeting_state == "held" and week.guest_count_known and not week.guest_count)
                ) for week in rolling)
            )
            tags = []
            if pending:
                tags.append(_("Reporte pendiente"))
            if no_guests:
                tags.append(_("Sin invitados en 30 días"))
            if contact_counts[cell.id]:
                tags.append(_("%s por contactar") % contact_counts[cell.id])
            if consolidation_counts[cell.id]:
                tags.append(_("Consolidación pendiente (%s)") % consolidation_counts[cell.id])
            total_attendance = sum(week.total_attended_celula for week in counted)
            rows.append({
                "cell": cell, "held": len(held), "historical": len(historical), "cancelled": cancelled, "pending": pending,
                "attendance_total": total_attendance,
                "average": "%.1f" % (total_attendance / len(counted)) if counted else "—",
                "unique_members": len(present), "guests": guests if guest_weeks else "—",
                "guest_coverage": "%s/%s" % (guest_weeks, len(counted)) if counted else "—",
                "tags": ", ".join(tags) or "—",
            })
        return rows

    @api.model
    def _closed_week_ends(self, start, cutoff):
        week_end = start + timedelta(days=(6 - start.weekday()) % 7)
        while week_end < cutoff:
            yield week_end
            week_end += timedelta(days=7)

    @api.model
    def _monthly_report_html(self, rows):
        headers = (
            _("Discipulado"), _("Célula"), _("Realizadas"), _("Históricas"), _("Canceladas"),
            _("Pendientes"), _("Asistencias de miembros"), _("Promedio de miembros"), _("Miembros distintos"), _("Invitados"),
            _("Reuniones con conteo"), _("Alertas"),
        )
        headings = Markup("").join(Markup("<th>%s</th>") % header for header in headers)
        table_rows = []
        for row in rows:
            values = (
                row["cell"].discipulado_id.display_name, row["cell"].display_name,
                row["held"], row["historical"], row["cancelled"], row["pending"], row["attendance_total"], row["average"],
                row["unique_members"], row["guests"], row["guest_coverage"], row["tags"],
            )
            table_rows.append(Markup("<tr>%s</tr>") % Markup("").join(Markup("<td>%s</td>") % value for value in values))
        if not table_rows:
            return Markup("<p>%s</p>") % _("No hay células activas en esta selección.")
        return (
            Markup('<table class="table table-sm" border="1" cellpadding="5"><thead><tr>%s</tr></thead><tbody>%s</tbody></table><p>%s</p>')
            % (headings, Markup("").join(table_rows), _(
                "Las semanas se atribuyen al mes en el que terminan. El promedio histórico incluye las semanas con asistencia marcada. "
                "Los seguimientos reflejan los casos abiertos al consultar el reporte."
            ))
        )

    @api.model
    def _schedule_monthly_attendance_cron(self):
        now = datetime.now(_REPORT_TIMEZONE)
        next_call = now.replace(hour=8, minute=0, second=0, microsecond=0)
        if next_call < now:
            next_call = now if now.day == 1 else next_call + timedelta(days=1)
        cron = self.env.ref("iem_church_management.cron_church_email_monthly_attendance")
        cron.nextcall = next_call.astimezone(timezone.utc).replace(tzinfo=None)

    @api.model
    def _cron_email_monthly_attendance(self, *, manual=False):
        today = self._report_today()
        if not manual and today.day != 1:
            return
        month = today.replace(day=1) - relativedelta(months=1)
        cells = self.env["iem.church.celula"].search([
            ("discipulado_id.active", "=", True), ("discipulado_id.red_id.active", "=", True),
        ], order="discipulado_id, name")
        rows_by_group = defaultdict(list)
        rows = self._monthly_rows(cells, month, today)
        for row in rows:
            group = row["cell"].discipulado_id
            rows_by_group[group].append(row)
            rows_by_group[group.red_id].append(row)

        dispatches = self.env["iem.church.monthly.dispatch"]
        for scope, scope_rows in rows_by_group.items():
            recipient = scope.pastor_id if scope._name == "iem.church.red" else scope.discipulador_id
            key = "%s:%s:%s" % (month, scope._name, scope.id)
            existing = dispatches.search([("dispatch_key", "=", key)], limit=1)
            if existing:
                continue
            if not recipient.email_normalized:
                _logger.warning("Reporte mensual IEM: falta correo para %s (%s).", scope._name, scope.id)
                continue
            link = "%s/odoo/action-%s" % (
                self.env["ir.config_parameter"].get_str("web.base.url", "").rstrip("/"),
                self.env.ref("iem_church_management.action_church_monthly_attendance").id,
            )
            try:
                with self.env.cr.savepoint():
                    dispatch = dispatches.create({"dispatch_key": key})
                    dispatch.mail_id = self.env["mail.mail"].create({
                        "subject": _("Asistencia mensual | %(scope)s | %(month)s", scope=scope.display_name, month=month.strftime("%m/%Y")),
                        "body_html": Markup('<p>%s</p>%s<p><a href="%s">%s</a></p>') % (
                            scope.display_name, self._monthly_report_html(scope_rows), link, _("Abrir reportes en Odoo"),
                        ),
                        "recipient_ids": [fields.Command.link(recipient.id)],
                        "email_from": self.env.company.email_formatted or False,
                        "auto_delete": False,
                    })
            except Exception:
                _logger.exception("No se pudo poner en cola el reporte mensual IEM de %s.", key)


class ChurchMonthlyDispatch(models.Model):
    _name = "iem.church.monthly.dispatch"
    _description = "Envío de reporte mensual de asistencia"

    dispatch_key = fields.Char(required=True)
    mail_id = fields.Many2one("mail.mail", ondelete="set null")

    _unique_dispatch = models.Constraint("UNIQUE(dispatch_key)", "El reporte de este período ya está en cola.")


class ChurchMonthlyAttendanceReport(models.TransientModel):
    _name = "iem.church.monthly.attendance.report"
    _description = "Reporte mensual de células"

    month = fields.Date(string="Mes", required=True, default=lambda self: (
        self.env["iem.church.weekly.attendance"]._report_today().replace(day=1) - relativedelta(months=1)
    ))
    discipulado_id = fields.Many2one("iem.church.discipulado", string="Discipulado")
    report_html = fields.Html(compute="_compute_report_html")

    def _cell_domain(self):
        self.ensure_one()
        domain = [("discipulado_id.active", "=", True), ("discipulado_id.red_id.active", "=", True)]
        if self.discipulado_id:
            domain.append(("discipulado_id", "=", self.discipulado_id.id))
        user = self.env.user
        if self.env.su or user.has_group("base.group_system") or user.has_group("iem_church_management.group_iem_admin"):
            return domain
        partner = user.partner_id
        if user.has_group("iem_church_management.group_iem_pastor_gobierno"):
            return domain + [("discipulado_id.red_id.predio_id", "=", partner.predio_id.id)]
        if user.has_group("iem_church_management.group_iem_pastor"):
            return domain + [
                ("discipulado_id.red_id.predio_id", "=", partner.predio_id.id),
                ("discipulado_id.red_id", "=", partner.red_id.id),
            ]
        return domain + [
            ("discipulado_id.red_id.predio_id", "=", partner.predio_id.id),
            ("discipulado_id.red_id", "=", partner.red_id.id),
            ("discipulado_id", "=", partner.discipulado_id.id),
        ]

    def action_open_followups(self):
        self.ensure_one()
        self.check_access("read")
        cells = self.env["iem.church.celula"].search(self._cell_domain())
        action = self.env["ir.actions.actions"]._for_xml_id("iem_church_management.action_church_cell_followup")
        action["domain"] = [("celula_id", "in", cells.ids)]
        return action

    @api.depends("month", "discipulado_id")
    def _compute_report_html(self):
        report = self.env["iem.church.weekly.attendance"]
        for wizard in self:
            cells = self.env["iem.church.celula"].search(wizard._cell_domain(), order="discipulado_id, name")
            rows = report._monthly_rows(cells, wizard.month, report._report_today()) if wizard.month else []
            wizard.report_html = report._monthly_report_html(rows)
