"""Builds the animated splash layers from the approved ASM splash artwork.

The artwork is one flattened image. To animate the logo, tagline and loader
separately without redrawing anything, it is split into layers that recompose
to the original pixels:
  - splash_plate.jpg : artwork with the logo, tagline and printed loader removed
                       (texture-preserving fill), used as the background
  - splash_logo.png  : logo exactly as in the artwork, with alpha
  - splash_tagline.png : tagline and divider exactly as in the artwork, with alpha
The printed loader is replaced in the app by a live indicator in the same style.

Usage (from mobile/; the approved artwork is tool/asm_splash_artwork.jpg):
  python tool/build_splash_layers.py tool/asm_splash_artwork.jpg --analyze
  python tool/build_splash_layers.py tool/asm_splash_artwork.jpg --out assets/splash
"""
import sys

from PIL import Image


def lum(p):
    return 0.299 * p[0] + 0.587 * p[1] + 0.114 * p[2]


def bright_bands(px, w, y0, y1, thr):
    bands, run = [], None
    for y in range(y0, y1):
        xs = [x for x in range(w) if lum(px[x, y]) > thr]
        if xs:
            if run is None:
                run = [y, y, min(xs), max(xs)]
            else:
                run[1], run[2], run[3] = y, min(run[2], min(xs)), max(run[3], max(xs))
        elif run is not None:
            bands.append(tuple(run))
            run = None
    if run:
        bands.append(tuple(run))
    return bands


def analyze(path):
    im = Image.open(path).convert("RGB")
    w, h = im.size
    px = im.load()
    print("size", w, h)
    for y0, y1, thr in ((int(h * 0.15), int(h * 0.46), 150), (int(h * 0.74), int(h * 0.86), 120)):
        for b in bright_bands(px, w, y0, y1, thr):
            print("bright band y=%d-%d x=%d-%d" % b)
    blue = [(x, y) for y in range(int(h * 0.39), int(h * 0.46)) for x in range(w)
            if px[x, y][2] > 180 and px[x, y][0] < 120]
    if blue:
        print("divider x=%d-%d y=%d-%d" % (min(p[0] for p in blue), max(p[0] for p in blue),
                                           min(p[1] for p in blue), max(p[1] for p in blue)))
    cyan = [(x, y) for y in range(int(h * 0.72), int(h * 0.82)) for x in range(int(w * 0.3), int(w * 0.7))
            if px[x, y][2] > 170 and px[x, y][1] > 150 and px[x, y][0] < 140]
    if cyan:
        print("loader arc x=%d-%d y=%d-%d" % (min(p[0] for p in cyan), max(p[0] for p in cyan),
                                              min(p[1] for p in cyan), max(p[1] for p in cyan)))


# Layer boxes in artwork pixels (left, top, right, bottom), from --analyze plus a
# small margin. lib/features/splash/splash_layout.dart uses the same values.
LOGO_BOX = (82, 272, 508, 354)
TAGLINE_BOX = (84, 380, 492, 436)
LOADER_BOX = (242, 762, 334, 862)


def coons_fill(px, box):
    """Smooth fill from the box border (bilinear Coons patch) - for the plain sky gradient."""
    l, t, r, b = box
    w, h = r - l, b - t
    top = [px[l + i, t] for i in range(w + 1)]
    bot = [px[l + i, b] for i in range(w + 1)]
    lef = [px[l, t + j] for j in range(h + 1)]
    rig = [px[r, t + j] for j in range(h + 1)]
    out = {}
    for j in range(1, h):
        v = j / h
        for i in range(1, w):
            u = i / w
            c = []
            for k in range(3):
                lerp = (1 - v) * top[i][k] + v * bot[i][k] + (1 - u) * lef[j][k] + u * rig[j][k]
                corners = ((1 - u) * (1 - v) * top[0][k] + u * (1 - v) * top[w][k]
                           + (1 - u) * v * bot[0][k] + u * v * bot[w][k])
                c.append(max(0, min(255, round(lerp - corners))))
            out[(l + i, t + j)] = tuple(c)
    return out


def water_fill(px, box, detail_shift_x, detail_gain=0.7):
    """Water: ripples run horizontally, so each row is interpolated between the
    box's left and right edges (2 px averages), plus fine ripple detail taken
    from the neighbouring water at the same rows (its row-mean removed)."""
    l, t, r, b = box
    w = r - l
    out = {}
    for y in range(t + 1, b):
        left = [sum(px[l - d, y][k] for d in (0, 1)) / 2 for k in range(3)]
        right = [sum(px[r + d, y][k] for d in (0, 1)) / 2 for k in range(3)]
        seg = [px[x + detail_shift_x, y] for x in range(l + 1, r)]
        mean = [sum(p[k] for p in seg) / len(seg) for k in range(3)]
        for i, x in enumerate(range(l + 1, r), start=1):
            u = i / w
            # Detail fades out towards the edges so the borders stay seamless.
            fade = min(u, 1 - u) * 2
            c = []
            for k in range(3):
                base = (1 - u) * left[k] + u * right[k]
                c.append(max(0, min(255, round(base + detail_gain * fade * (seg[i - 1][k] - mean[k])))))
            out[(x, y)] = tuple(c)
    return out


def matte(orig, plate, box):
    """Foreground layer (RGBA) such that layer over plate == original."""
    l, t, r, b = box
    layer = Image.new("RGBA", (r - l, b - t), (0, 0, 0, 0))
    lp = layer.load()
    for y in range(t, b):
        for x in range(l, r):
            p, q = orig[x, y], plate[x, y]
            a = max((p[k] - q[k]) / (255 - q[k]) if q[k] < 255 else 0 for k in range(3))
            a = max(0.0, min(1.0, a))
            if a < 0.02:
                continue
            f = tuple(max(0, min(255, round(q[k] + (p[k] - q[k]) / a))) for k in range(3))
            lp[x - l, y - t] = f + (round(a * 255),)
    return layer


def build(path, out_dir):
    import os
    src = Image.open(path).convert("RGB")
    orig = src.load()
    plate_img = src.copy()
    plate = plate_img.load()
    for box in (LOGO_BOX, TAGLINE_BOX):
        for xy, c in coons_fill(orig, box).items():
            plate[xy] = c
    shift = -(LOADER_BOX[2] - LOADER_BOX[0])
    for xy, c in water_fill(orig, LOADER_BOX, shift).items():
        plate[xy] = c

    logo = matte(orig, plate, LOGO_BOX)
    tagline = matte(orig, plate, TAGLINE_BOX)

    os.makedirs(out_dir, exist_ok=True)
    plate_img.save(os.path.join(out_dir, "splash_plate.jpg"), quality=92, optimize=True, progressive=True)
    logo.save(os.path.join(out_dir, "splash_logo.png"), optimize=True)
    tagline.save(os.path.join(out_dir, "splash_tagline.png"), optimize=True)

    # Verification: recomposed layers must match the artwork outside the loader box.
    comp = Image.open(os.path.join(out_dir, "splash_plate.jpg")).convert("RGBA")
    comp.alpha_composite(logo, (LOGO_BOX[0], LOGO_BOX[1]))
    comp.alpha_composite(tagline, (TAGLINE_BOX[0], TAGLINE_BOX[1]))
    cp = comp.convert("RGB").load()
    worst, total, n = 0, 0, 0
    for box in (LOGO_BOX, TAGLINE_BOX):
        for y in range(box[1], box[3]):
            for x in range(box[0], box[2]):
                d = max(abs(cp[x, y][k] - orig[x, y][k]) for k in range(3))
                worst, total, n = max(worst, d), total + d, n + 1
    print("recomposition vs artwork in logo/tagline boxes: mean %.2f, max %d (0-255)" % (total / n, worst))
    return comp


def preview(comp, path):
    """3x zoom of the loader area of the recomposed plate, for visual review."""
    l, t, r, b = LOADER_BOX
    crop = comp.convert("RGB").crop((l - 60, t - 40, r + 60, b + 40))
    crop.resize((crop.width * 3, crop.height * 3), Image.NEAREST).save(path)


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[2] == "--analyze":
        analyze(sys.argv[1])
    elif len(sys.argv) >= 4 and sys.argv[2] == "--out":
        result = build(sys.argv[1], sys.argv[3])
        if len(sys.argv) >= 6 and sys.argv[4] == "--preview":
            preview(result, sys.argv[5])
    else:
        print(__doc__)
