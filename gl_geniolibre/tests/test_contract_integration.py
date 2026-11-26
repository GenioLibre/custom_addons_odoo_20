from odoo import Command
from odoo.tests import TransactionCase, tagged


@tagged('post_install', '-at_install')
class TestContractIntegration(TransactionCase):
    def test_contract_xml_ids(self):
        for name in (
            'model_subscription_contracts',
            'model_subscription_contracts_line',
            'action_report_subscription_contracts',
            'subscription_contracts_view_form',
            'ir_cron_refresh_contract_status',
            'portal_my_home_contracts',
        ):
            self.assertTrue(self.env.ref('gl_geniolibre.' + name))
        report = self.env.ref('gl_geniolibre.action_report_subscription_contracts')
        self.assertEqual(report.report_name, 'gl_geniolibre.report_subscription_contracts')

    def test_contract_cron_only_refreshes_status(self):
        cron = self.env.ref('gl_geniolibre.ir_cron_refresh_contract_status')
        self.assertEqual(cron.code, 'model.subscription_contract_state_change()')

    def test_portal_cannot_write_contracts(self):
        portal_user = self.env['res.users'].create({
            'name': 'Portal Contracts',
            'login': 'gl_contract_portal',
            'group_ids': [Command.set([self.env.ref('base.group_portal').id])],
        })
        for model_name in ('subscription.contracts', 'subscription.contracts.line'):
            self.assertFalse(self.env[model_name].with_user(portal_user).has_access('write'))
