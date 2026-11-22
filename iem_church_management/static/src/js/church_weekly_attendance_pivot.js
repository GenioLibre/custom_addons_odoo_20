import { download } from "@web/core/network/download";
import { registry } from "@web/core/registry";
import { PivotRenderer } from "@web/views/pivot/pivot_renderer";
import { pivotView } from "@web/views/pivot/pivot_view";

class WeeklyAttendancePivotRenderer extends PivotRenderer {
    async onWeeklyAttendanceExportClicked() {
        await download({
            url: "/iem_church_management/weekly_attendance/export_xlsx",
            data: {
                domain: JSON.stringify(this.model.searchParams.domain || []),
                context: JSON.stringify(this.model.searchParams.context || {}),
            },
        });
    }
}

registry.category("views").add("iem_weekly_attendance_pivot", {
    ...pivotView,
    Renderer: WeeklyAttendancePivotRenderer,
    buttonTemplate: "iem_church_management.WeeklyAttendancePivot.Buttons",
});
