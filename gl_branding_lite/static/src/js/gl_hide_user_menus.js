/** @odoo-module **/

import { UserMenu } from "@web/webclient/user_menu/user_menu";
import { patch } from "@web/core/utils/patch";
import { registry } from "@web/core/registry";

const userMenuRegistry = registry.category("user_menuitems");

patch(UserMenu.prototype, {
    setup() {
        super.setup();

        // Claves vigentes en Odoo 20.
        // Conservamos Preferencias y Cerrar sesión.
        for (const key of ["support", "shortcuts", "separator", "install_pwa"]) {
            if (userMenuRegistry.contains(key)) {
                userMenuRegistry.remove(key);
            }
        }
    },
});
