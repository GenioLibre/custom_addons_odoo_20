import logging
from io import BytesIO

from PIL import ImageOps, WebPImagePlugin

from odoo import api, fields, models
from odoo.tools.image import image_data_uri


_logger = logging.getLogger(__name__)


class SaleOrderLine(models.Model):
    """Inherits the model sale.order.line to add a field"""
    _inherit = 'sale.order.line'

    order_line_image = fields.Binary(string="Imagen",
                                     related="product_id.image_1920",
                                     help='Imagen del producto en la línea de pedido de venta')
    product_template_name = fields.Char(
            string="Nombre de Plantilla",
            compute='_compute_product_template_name',
            store=True
        )

    @api.depends('product_id')
    def _compute_product_template_name(self):
        for line in self:
            line.product_template_name = line.product_id.product_tmpl_id.name if line.product_id else False
    def _get_tithor_report_image_src(self):
        self.ensure_one()
        image = self.product_id.image_256
        if not image:
            return False
        if image.mimetype != 'image/webp':
            return image_data_uri(image)

        # wkhtmltopdf cannot display WebP. Keep transparency in the report.
        try:
            with image.open() as stream, WebPImagePlugin.WebPImageFile(stream) as photo:
                thumbnail = ImageOps.exif_transpose(photo)
                thumbnail.thumbnail((256, 256))
                png = BytesIO()
                thumbnail.save(png, format='PNG')
        except OSError:
            _logger.warning("Could not convert WebP image for sale order line %s", self.id)
            return False
        return image_data_uri(png.getbuffer())
