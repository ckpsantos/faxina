"""Transforma a arte quadrada (icone/arte.png) em AppIcon.icns no padrão do macOS.
Uso: python3 icone/montar.py"""
import pathlib
import subprocess

from PIL import Image, ImageDraw

aqui = pathlib.Path(__file__).parent
arte = Image.open(aqui / "arte.png").convert("RGBA")
lado = min(arte.size)
esq, topo = (arte.width - lado) // 2, (arte.height - lado) // 2
arte = arte.crop((esq, topo, esq + lado, topo + lado)).resize((824, 824), Image.LANCZOS)

# Grade do macOS: quadrado arredondado de 824 px centrado em 1024, raio ~185.
mascara = Image.new("L", (824 * 4, 824 * 4), 0)
ImageDraw.Draw(mascara).rounded_rectangle((0, 0, 824 * 4 - 1, 824 * 4 - 1), radius=185 * 4, fill=255)
mascara = mascara.resize((824, 824), Image.LANCZOS)
tela = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
tela.paste(arte, (100, 100), mascara)
tela.save(aqui / "icone-1024.png")

conjunto = aqui / "AppIcon.iconset"
conjunto.mkdir(exist_ok=True)
for tamanho in (16, 32, 128, 256, 512):
    tela.resize((tamanho, tamanho), Image.LANCZOS).save(conjunto / f"icon_{tamanho}x{tamanho}.png")
    tela.resize((tamanho * 2, tamanho * 2), Image.LANCZOS).save(conjunto / f"icon_{tamanho}x{tamanho}@2x.png")
subprocess.run(["iconutil", "-c", "icns", str(conjunto), "-o", str(aqui / "AppIcon.icns")], check=True)
print("ok:", aqui / "AppIcon.icns")
