"""Image de mentira: solo existe para que reportlab importe; abrir imágenes no está soportado."""


class Image:
    pass


def open(*_args, **_kwargs):
    raise OSError("El informe en iPhone no admite imágenes")

