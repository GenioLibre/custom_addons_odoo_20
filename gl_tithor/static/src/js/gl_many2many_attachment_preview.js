/** @odoo-module */

import { Many2XBinary } from "@web/views/fields/many2x_binary/many2x_binary";
import { FileModel } from "@web/core/file_viewer/file_model";
import { useFileViewer } from "@web/core/file_viewer/file_viewer_hook";
import { patch } from "@web/core/utils/patch";

// Al hacer clic en la miniatura de un adjunto se abre el visor de archivos
// (en lugar de descargar). La descarga sigue disponible desde el nombre.
patch(Many2XBinary.prototype, {
    setup() {
        super.setup(...arguments);
        this.fileViewer = useFileViewer();
    },
    onClickPreview(file) {
        const viewerFiles = this.props.files.map((f) =>
            Object.assign(new FileModel(), {
                id: f.id,
                name: f.name,
                mimetype: f.mimetype,
            })
        );
        const current = viewerFiles.find((f) => f.id === file.id);
        if (current) {
            this.fileViewer.open(current, viewerFiles);
        }
    },
});
