/** @odoo-module **/

import { WebClient } from "@web/webclient/webclient";
import { patch } from "@web/core/utils/patch";

patch(WebClient.prototype, {
    setup() {
        // El título inicial ya viene del parámetro web.base.title
        // inyectado en web.webclient_bootstrap por ir.ui.view.
        const brandTitle = document.title;
        super.setup();

        if (brandTitle && brandTitle !== "Odoo") {
            this.title.setParts({ gl_branding: brandTitle });
        }
    },
});
