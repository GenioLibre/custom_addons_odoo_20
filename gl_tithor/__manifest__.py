# -*- coding: utf-8 -*-
{
    'name': "TITHOR - Custom Development",
    'version': '20.0.1.0.0',
    'author': 'GenioLibre',

    'summary': """
        Tithor Custom""",

    'description': """
        Desarrollo personalizado para gestion de Tithor
    """,

    'website': "Tithor.com",
    'application': True,
    'license': 'LGPL-3',
    'category': 'Customizations',

    'depends': ['base', 'mail', 'purchase', 'sale', 'sale_management'],
    'external_dependencies': {'python': ['openpyxl']},

    'data': [
        'security/ir.model.access.csv',
        'data/gl_confection_sequence.xml',

        'views/gl_res_config_settings_views.xml',
        'views/gl_sale_order_views.xml',
        'views/gl_sale_order_line_views.xml',
        'views/gl_purchase_order_views.xml',

        'report/gl_print_recibo_venta.xml',
        'report/gl_sale_pre_quote.xml',
        'report/gl_sale_order_report.xml',
    ],
    'assets': {
        'web.assets_backend': [
            'gl_tithor/static/src/js/gl_many2many_attachment_preview.js',
            'gl_tithor/static/src/js/gl_delayed_reload.js',
            'gl_tithor/static/src/xml/gl_many2many_attachment_preview_template.xml',
        ],
    },
}
