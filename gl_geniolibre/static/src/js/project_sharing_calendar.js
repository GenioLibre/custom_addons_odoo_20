import { patch } from "@web/core/utils/patch";
import { ControlPanel } from "@web/search/control_panel/control_panel";
import { session } from "@web/session";

patch(ControlPanel.prototype, {
    get glPublicationCalendarUrl() {
        return session.project_id && `/my/projects/${session.project_id}/calendar`;
    },
});
