#!/usr/bin/env python3
"""
make-icon.py — draw the RadialMenu app icon.

The icon IS the menu: eight seats on a ring, one of them nudged out and lit,
around a hollow origin. Hollow rather than filled, because that is what the
component actually draws — a ring you aim through, not a spot you land on.

Everything below is a FRACTION of the canvas, so one description renders every
size. Needs Pillow (`pip3 install pillow`); the PNGs it writes are committed, so
you only need it if you want to change the drawing.

    python3 Tools/make-icon.py [path/to/Assets.xcassets]
"""
import math
import os
import sys

from PIL import Image, ImageDraw, ImageFont

# ── the drawing, in fractions of the canvas ──────────────────────────────────
BG          = (0x2B, 0x2B, 0x30, 255)   # dark gray, faintly cool
SEAT        = (0xC2, 0xC2, 0xCE, 255)   # the unlit ring circles
LIT         = (0xFF, 0xFF, 0xFF, 255)   # the one under your hand
LIT_FILL    = 1.0                        # the lit seat is SOLID — hollow is "not this one"
ORIGIN      = (0x86, 0x86, 0x95, 255)   # the hollow centre
WORD_INK    = (0x9E, 0x9E, 0xAC, 255)   # the name, inside it

SEATS       = 8
LIT_SEAT    = 1                          # 45° — up and to the right
RING        = 0.293                      # ring radius
SEAT_R      = 0.0732                     # seat radius
NUDGE       = 0.0254                     # how far the lit seat leans out
LIT_R       = 0.0859                     # …and how much bigger it gets
ORIGIN_R    = 0.166                      # the centre ring — a circle, not a dot
LINE        = 0.0127                     # thin, and the same thin everywhere
LIT_LINE    = 0.0166
ORIGIN_LINE = 0.0122

WORD        = "menu"
WORD_FILL   = 0.58                       # of the ring's INNER diameter
WORD_TRACK  = 0.05                       # letter spacing, × font size

# Poppins first on purpose: a geometric sans whose bowls are true circles, which
# is the same shape the whole icon is made of. The rest are fallbacks so this
# still renders on a Mac with no Linux font tree.
FONTS = (
    "/usr/share/fonts/truetype/google-fonts/Poppins-Medium.ttf",
    "/System/Library/Fonts/Supplemental/Futura.ttc",
    "/System/Library/Fonts/SFNS.ttf",
    "/System/Library/Fonts/Helvetica.ttc",
    "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
)

SS = 8                                   # supersampling


def load_font(size):
    for path in FONTS:
        try:
            return ImageFont.truetype(path, size)
        except Exception:
            continue
    return None


def tracked_width(d, text, font, track):
    return sum(d.textlength(c, font=font) for c in text) + track * (len(text) - 1)


def draw_word(d, cx, cy, target, colour, text):
    """`text` fitted to `target` points wide and centred on its own INK.

    Ink, not metrics: "menu" has no ascender and no descender, so its metric box
    sits well above its optical middle and centring on that box would float the
    word toward the top of the ring."""
    guess = max(int(target / 2), 8)
    f = load_font(guess)
    if f is None:
        print("no usable font found — drawing the icon without the word")
        return
    w = tracked_width(d, text, f, WORD_TRACK * guess)
    if w <= 0:
        return
    size = max(int(guess * target / w), 4)
    f = load_font(size)
    track = WORD_TRACK * size
    w = tracked_width(d, text, f, track)

    box = d.textbbox((0, 0), text, font=f)
    x = cx - w / 2
    y = cy - (box[3] - box[1]) / 2 - box[1]
    for c in text:
        d.text((x, y), c, font=f, fill=colour)
        x += d.textlength(c, font=f) + track


def over(top, bottom, alpha):
    """Blend by hand. PIL's `fill` WRITES pixels rather than compositing them,
    so a translucent fill survives into the RGBA buffer and then flattens to
    solid white the moment the icon is converted to RGB — which is exactly how
    the lit seat came out as a filled disc the first time."""
    return tuple(int(round(t * alpha + b * (1 - alpha))) for t, b in zip(top[:3], bottom[:3])) + (255,)


def draw(size, *, background=True):
    """One icon at `size`, drawn 8x and downsampled."""
    n = size * SS
    im = Image.new("RGBA", (n, n), BG if background else (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    c = n / 2

    def ring(cx, cy, r, colour, width, fill=None):
        box = [cx - r, cy - r, cx + r, cy + r]
        d.ellipse(box, outline=colour, width=max(int(round(width)), 1), fill=fill)

    for i in range(SEATS):
        lit = i == LIT_SEAT
        a = math.radians(360 / SEATS * i - 90)
        radius = (RING + (NUDGE if lit else 0)) * n
        ring(c + math.cos(a) * radius, c + math.sin(a) * radius,
             (LIT_R if lit else SEAT_R) * n,
             LIT if lit else SEAT,
             (LIT_LINE if lit else LINE) * n,
             fill=over(LIT, BG, LIT_FILL) if lit else None)

    ring(c, c, ORIGIN_R * n, ORIGIN, ORIGIN_LINE * n)
    if WORD:
        inner = ORIGIN_R * n - ORIGIN_LINE * n / 2
        draw_word(d, c, c, 2 * inner * WORD_FILL, WORD_INK, WORD)
    return im.resize((size, size), Image.LANCZOS)


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "Sources/Assets.xcassets"
    flat = os.path.join(root, "AppIconFlat.appiconset")
    stack = os.path.join(root, "AppIcon.solidimagestack")

    wrote = []

    def save(im, path):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        im.save(path)
        wrote.append(path)

    save(draw(1024).convert("RGB"), os.path.join(flat, "icon-ios-1024.png"))
    for pt in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            save(draw(pt * scale).convert("RGB"),
                 os.path.join(flat, f"icon-mac-{pt}@{scale}x.png"))

    # visionOS parallax: the field goes back, the menu comes forward.
    save(Image.new("RGBA", (512, 512), BG),
         os.path.join(stack, "Back.solidimagestacklayer/Content.imageset/back.png"))
    save(draw(512, background=False),
         os.path.join(stack, "Front.solidimagestacklayer/Content.imageset/front.png"))

    for p in wrote:
        print("wrote", p)


if __name__ == "__main__":
    main()
