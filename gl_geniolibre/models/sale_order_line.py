from odoo import fields, models


class SaleOrderLine(models.Model):
    _inherit = 'sale.order.line'

    price_total_with_tax = fields.Monetary(
        string="Precio Total (c/IGV)", related='price_total', store=True,
    )
    contract_id = fields.Many2one('subscription.contracts', string='Contracts', help='For adding Contracts in sale order line')
