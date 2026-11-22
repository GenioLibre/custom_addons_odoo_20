from collections import defaultdict

from odoo import _, api, fields, models
from odoo.exceptions import AccessError, ValidationError


class ChurchCellFollowup(models.Model):
    _name = "iem.church.cell.followup"
    _description = "Seguimiento de célula"
    _rec_name = "celula_id"
    _order = "state, create_date desc"

    celula_id = fields.Many2one("iem.church.celula", string="Célula", required=True, ondelete="restrict", index=True)
    discipulado_id = fields.Many2one(related="celula_id.discipulado_id", store=True)
    red_id = fields.Many2one(related="discipulado_id.red_id", store=True)
    predio_id = fields.Many2one(related="red_id.predio_id", store=True)
    responsible_id = fields.Many2one(related="celula_id.lider_id", string="Líder de célula")
    kind = fields.Selection([("guest", "Invitado"), ("absence", "Inasistencia")], default="guest", required=True)
    guest_name = fields.Char(string="Nombre del invitado")
    guest_since = fields.Date(string="Primera visita", default=fields.Date.context_today)
    member_id = fields.Many2one("church.member", string="Miembro", ondelete="restrict")
    last_attended = fields.Date(string="Última semana con asistencia")
    missed_count = fields.Integer(string="Faltas confirmadas")
    state = fields.Selection([
        ("pending", "Por contactar"), ("contacted", "Contactado"),
        ("excused", "Justificado"), ("transferred", "Trasladado"),
        ("integrated", "Integrado"), ("returned", "Volvió a asistir"),
        ("reviewed", "Alerta corregida"),
    ], default="pending", required=True, index=True)
    next_contact = fields.Date(string="Próximo contacto")
    note = fields.Text(string="Nota de seguimiento")

    _absence_episode_unique = models.Constraint(
        "UNIQUE(celula_id, member_id, last_attended)",
        "Ya existe un seguimiento para este período de inasistencia.",
    )

    @api.model_create_multi
    def create(self, vals_list):
        if not self.env.su and any(vals.get("kind", self.env.context.get("default_kind", "guest")) != "guest" for vals in vals_list):
            raise AccessError(_("Las alertas de inasistencia se generan automáticamente."))
        return super().create(vals_list)

    def write(self, vals):
        protected = {"celula_id", "kind", "member_id", "last_attended", "missed_count"}
        if not self.env.su and protected.intersection(vals):
            raise AccessError(_("Solo el sistema puede cambiar la identificación de un seguimiento."))
        return super().write(vals)

    @api.constrains("kind", "guest_name", "guest_since", "member_id", "last_attended")
    def _check_subject(self):
        for case in self:
            if case.kind == "guest" and (not (case.guest_name or "").strip() or not case.guest_since):
                raise ValidationError(_("Indica el nombre y la fecha de visita del invitado."))
            if case.kind == "absence" and (not case.member_id or not case.last_attended):
                raise ValidationError(_("La alerta necesita el miembro y su última semana de asistencia."))

    @api.model
    def _cron_update_absences(self):
        today = self.env["iem.church.weekly.attendance"]._report_today()
        for cell in self.env["iem.church.celula"].search([
            ("discipulado_id.active", "=", True), ("discipulado_id.red_id.active", "=", True),
        ]):
            self._update_cell_absences(cell, today)

    @api.model
    def _update_cell_absences(self, cell, today):
        active_members = self.env["church.member"].search([
            ("celula_id", "=", cell.id), ("member_status", "=", "active"),
        ])
        weeks = self.env["iem.church.weekly.attendance"].search([
            ("celula_id", "=", cell.id), ("week_end", "<", today),
            ("meeting_state", "not in", ["cancelled", "draft"]),
        ], order="week_start, id")
        histories = defaultdict(list)
        for week in weeks:
            for line in week.line_ids:
                if line.attended_celula or (week.meeting_state == "held" and line.absence_known):
                    histories[line.member_id.id].append((week.week_start, line.attended_celula))

        cases = self.search([("celula_id", "=", cell.id), ("kind", "=", "absence")])
        by_episode = {(case.member_id.id, case.last_attended): case for case in cases}
        current = self.browse()
        active_ids = set(active_members.ids)
        for member in active_members:
            last_attended, missed = False, 0
            for week, attended in histories[member.id]:
                if attended:
                    last_attended, missed = week, 0
                elif last_attended:
                    missed += 1
            if missed < 3:
                continue
            key = (member.id, last_attended)
            case = by_episode.get(key)
            if not case:
                case = self.create({
                    "celula_id": cell.id, "kind": "absence", "member_id": member.id,
                    "last_attended": last_attended, "missed_count": missed,
                })
            else:
                vals = {}
                if case.missed_count != missed:
                    vals["missed_count"] = missed
                if case.state == "reviewed":
                    vals["state"] = "pending"
                if vals:
                    case.write(vals)
            current |= case

        for case in (cases - current).filtered(lambda item: item.state in ("pending", "contacted", "excused")):
            if case.member_id.id not in active_ids:
                if case.member_id.celula_id and case.member_id.celula_id != cell:
                    case.state = "transferred"
                else:
                    case.state = "reviewed"
            else:
                returned = any(attended and week > case.last_attended for week, attended in histories[case.member_id.id])
                case.state = "returned" if returned else "reviewed"
