/** @odoo-module */

import { Many2XBinary } from "@web/views/fields/many2x_binary/many2x_binary";
import { patch } from "@web/core/utils/patch";
import { useService } from "@web/core/utils/hooks";
import { useFileViewer } from "@web/core/file_viewer/file_viewer_hook";

const Many2XBinaryPatch = {
    setup() {
        super.setup(...arguments);
        this.store = useService("mail.store");
        this.fileViewer = useFileViewer();
    },
    onClickPreview(id) {

        const attachments = this.props.files.map(f => this.store.Attachment.insert({
            id: f.id,
            filename: f.name,
            name: f.name,
            mimetype: f.mimetype,
        }));

        const attachment = attachments.find(a => a.id === id);
        if (attachment) {
            this.fileViewer.open(attachment, attachments);
        }
    }
};

patch(Many2XBinary.prototype, Many2XBinaryPatch);
