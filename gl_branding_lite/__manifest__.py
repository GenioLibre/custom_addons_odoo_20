# -*- coding: utf-8 -*-
{
    "name": "GenioLibre - Branding Lite",
    "version": "20.0.1.0.0",
    "author": "GenioLibre",
    "summary": "Branding básico para el backend de Odoo 20",
    "description": """
        Branding básico para Odoo 20: título personalizado de ventana,
        limpieza del menú de usuario y ocultación de Powered by Odoo
        en la pantalla de inicio de sesión.
    """,
    "website": "https://geniolibre.com",
    "application": False,
    "installable": True,
    "license": "LGPL-3",
    "category": "Customizations",
    "depends": ["base_setup", "web"],
    "data": [
        "views/gl_branding_lite.xml",
    ],
    "assets": {
        "web.assets_backend": [
            "gl_branding_lite/static/src/js/gl_hide_user_menus.js",
            "gl_branding_lite/static/src/js/gl_web_window_title.js",
        ],
    },
}
