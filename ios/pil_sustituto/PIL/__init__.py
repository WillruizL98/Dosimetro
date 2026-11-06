"""Sustituto mínimo de Pillow para iPhone.

reportlab importa PIL al cargarse, pero el informe no usa imágenes. La rueda de Pillow para
iOS depende de libjpeg/libpng que no vienen incluidas, así que en iPhone se usa este paquete.
"""

__version__ = "0.0-sustituto"

