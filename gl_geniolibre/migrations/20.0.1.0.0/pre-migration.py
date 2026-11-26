def migrate(cr, version):
    legacy_module = 'sales_contract_and_recurring_invoices'
    cr.execute(
        "SELECT 1 FROM ir_module_module WHERE name = %s AND state NOT IN ('uninstalled', 'uninstallable')",
        (legacy_module,),
    )
    if cr.fetchone():
        raise RuntimeError(
            'Run gl_geniolibre/migrations/merge_contracts.sql with Odoo stopped '
            'before upgrading; do not uninstall the legacy addon.'
        )
    cr.execute("SELECT 1 FROM ir_model_data WHERE module = %s LIMIT 1", (legacy_module,))
    if cr.fetchone():
        raise RuntimeError('Legacy contract XML IDs remain; migration required.')

    # Replace the legacy portal view with a native portal entry under the same XML ID.
    cr.execute("""
        UPDATE ir_ui_view
           SET active = false
         WHERE key = 'gl_geniolibre.portal_my_home_contracts'
            OR id IN (
                SELECT res_id FROM ir_model_data
                 WHERE module = 'gl_geniolibre' AND name = 'portal_my_home_contracts'
                   AND model = 'ir.ui.view'
            )
    """)
    cr.execute("""
        DELETE FROM ir_model_data
         WHERE module = 'gl_geniolibre'
           AND (model IN ('ir.model.access', 'ir.rule')
                OR (name = 'portal_my_home_contracts' AND model = 'ir.ui.view'))
    """)
