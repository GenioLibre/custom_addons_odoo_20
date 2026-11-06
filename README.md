# custom_addons_odoo_20

Módulos personalizados para Odoo 20 Community.

Este repositorio está preparado para ser clonado automáticamente por el instalador de Odoo 20 en:

`/opt/odoo20/odoo/custom_addons`

El archivo de configuración de Odoo incluye este directorio en `addons_path`.

## Estructura

Cada módulo debe vivir directamente en la raíz del repositorio:

```
custom_addons_odoo_20/
├── modulo_uno/
│   ├── __init__.py
│   ├── __manifest__.py
│   ├── models/
│   ├── views/
│   └── security/
├── modulo_dos/
└── requirements.txt
```

## Dependencias Python

Si un módulo necesita librerías Python adicionales, agrégalas a `requirements.txt`.
El instalador las instalará dentro del virtualenv de Odoo 20.

## Actualizar módulos en el servidor

```bash
cd /opt/odoo20/odoo/custom_addons
sudo -u odoo20 git pull
systemctl restart odoo20
```

Servidor actual: `192.168.1.250`
