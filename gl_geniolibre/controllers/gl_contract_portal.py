# -*- coding: utf-8 -*-

from odoo import http
from odoo.http import request
from odoo.addons.portal.controllers.portal import CustomerPortal

class PortalAccount(CustomerPortal):
    """ Super customer portal and get count of contracts """

    def _prepare_portal_counter_values(self, counter):
        if counter == 'contract_count':
            user = request.env.user
            domain = [] if user.has_group('base.group_system') else [('partner_id', '=', user.partner_id.id)]
            return 'subscription.contracts', domain, 'sudo'
        return super()._prepare_portal_counter_values(counter)


class ContractsController(http.Controller):
    """Handles listing and displaying subscription contracts in the portal"""

    @http.route(['/my/contracts'], type='http', auth='user', website=True)
    def portal_contracts_list(self, **kwargs):
        # Obtener el partner_id del usuario actual
        partner_id = request.env.user.partner_id.id

        # Dominio para filtrar solo contratos donde el usuario es el cliente
        domain = [
            ('partner_id', '=', partner_id)
        ]

        # Buscar los contratos (con sudo() para evitar problemas de permisos)
        records = request.env['subscription.contracts'].sudo().search(domain)

        # Renderizar la plantilla con los registros
        return request.render('gl_geniolibre.tmp_contract_details', {
            'records': records,
            'page_name': 'contracts'  # Útil para estilos/css si lo necesitas
        })

    @http.route(['/my/contracts/<int:contract_id>'], type='http', auth='user', website=True)
    def portal_contract_details(self, contract_id, **kwargs):
        # Browse the contract record (sudo to avoid access restrictions)
        record = request.env['subscription.contracts'].sudo().browse(contract_id).exists()
        if not record:
            raise request.not_found()
        # Ensure record belongs to the user unless admin
        if not request.env.user.has_group('base.group_system') and record.partner_id != request.env.user.partner_id:
            return request.redirect('/my')
        return request.render('gl_geniolibre.contract_details', {
            'record': record
        })

    @http.route(['/my/contracts/<int:contract_id>/print'], type='http', auth='user', website=True)
    def portal_contract_print(self, contract_id, **kwargs):
        record = request.env['subscription.contracts'].sudo().browse(contract_id).exists()
        if not record or (not request.env.user.has_group('base.group_system') and record.partner_id != request.env.user.partner_id):
            raise request.not_found()
        pdf_content, _ = request.env['ir.actions.report'].sudo()._render_qweb_pdf(
            'gl_geniolibre.action_report_subscription_contracts', record.ids,
        )
        # Return PDF response
        headers = [
            ('Content-Type', 'application/pdf'),
            ('Content-Length', len(pdf_content)),
        ]
        return request.make_response(pdf_content, headers=headers)
