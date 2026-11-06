# -*- coding: utf-8 -*-

from odoo import fields, models


CONFIG_PARAM_WEB_WINDOW_TITLE = "web.base.title"


class ResConfigSettings(models.TransientModel):
    _inherit = "res.config.settings"

    web_window_title = fields.Char(
        string="Window Title",
        config_parameter=CONFIG_PARAM_WEB_WINDOW_TITLE,
        help="Título personalizado que se muestra en la pestaña del navegador.",
    )
