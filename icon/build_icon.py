"""Render icon/makepack.svg -> makepack.ico via Edge headless (no extra deps beyond Pillow).
Usage: python icon/build_icon.py [svg] [ico]   |   python icon/build_icon.py --preview out.png svg1 svg2 ...
"""
import os, subprocess, sys, tempfile
from PIL import Image, ImageDraw

EDGE = r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"
SIZES = [256, 128, 64, 48, 40, 32, 24, 20, 16]
HERE = os.path.dirname(os.path.abspath(__file__))


def render(svg, sizes=SIZES):
    """Return {size: RGBA Image} rendered natively at each size (one Edge run per svg)."""
    svg = os.path.abspath(svg)
    tmp = tempfile.mkdtemp(prefix="makepack-icon-")
    html = os.path.join(tmp, "sheet.html")
    xs, x = [], 0
    for s in sizes:
        xs.append(x); x += s + 8
    imgs = "".join(f'<img src="file:///{svg.replace(os.sep, "/")}" style="position:absolute;left:{xs[i]}px;top:0;width:{s}px;height:{s}px">'
                   for i, s in enumerate(sizes))
    open(html, "w", encoding="utf-8").write(f'<html><body style="margin:0;background:transparent">{imgs}</body></html>')
    png = os.path.join(tmp, "sheet.png")
    subprocess.run([EDGE, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--force-device-scale-factor=1",
                    "--default-background-color=00000000", f"--window-size={x + 16},{sizes[0] + 16}",
                    f"--user-data-dir={os.path.join(tmp, 'prof')}", f"--screenshot={png}", "file:///" + html.replace(os.sep, "/")],
                   check=True, capture_output=True, timeout=60)
    sheet = Image.open(png).convert("RGBA")
    return {s: sheet.crop((xs[i], 0, xs[i] + s, s)) for i, s in enumerate(sizes)}


def build_ico(svg, ico):
    frames = render(svg)
    frames[256].save(ico, format="ICO", sizes=[(s, s) for s in SIZES], append_images=[frames[s] for s in SIZES[1:]])
    print(f"{ico}: {os.path.getsize(ico)} bytes, sizes {SIZES}")


def preview(out, svgs):
    show = [256, 128, 64, 48, 32, 24, 16]
    row_h, pad = 300, 16
    W = pad + sum(s + pad for s in show)
    sheet = Image.new("RGBA", (W * 2, row_h * len(svgs)), (0, 0, 0, 0))
    d = ImageDraw.Draw(sheet)
    for r, svg in enumerate(svgs):
        fr = render(svg, show)
        for half, bg in enumerate([(243, 243, 243, 255), (32, 32, 32, 255)]):
            d.rectangle((half * W, r * row_h, half * W + W, r * row_h + row_h), fill=bg)
            x = half * W + pad
            for s in show:
                sheet.alpha_composite(fr[s], (x, r * row_h + pad + (256 - s) // 2))
                x += s + pad
            d.text((half * W + pad, r * row_h + row_h - 22), os.path.basename(svg), fill=(128, 128, 128, 255))
    sheet.save(out)
    print(out)


if __name__ == "__main__":
    a = sys.argv[1:]
    if a and a[0] == "--preview":
        preview(a[1], a[2:])
    else:
        build_ico(a[0] if a else os.path.join(HERE, "makepack.svg"), a[1] if len(a) > 1 else os.path.join(HERE, "makepack.ico"))
