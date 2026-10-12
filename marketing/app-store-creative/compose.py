"""Compose the App Store creative assets (product page header, search
results, universal) from real app renders.

Inputs are produced by MarketingSnapshotTests (renderFleetWeekHUD and
renderFleetWeekCardParts) into /private/tmp/tailspot_snaps/marketing:
  mkt_01_fleet_week.png        the HUD screen (C-27J over the Golden Gate)
  part_card_<name>.png         SettledCatchCard renders, transparent, 4x
Nothing here draws app UI: every card and the HUD come from the app's own
views. This script only lays them out on the deck's dusk gradient and sets
the headline.

Specs (App Store Connect → creative assets): header 21:9 3840x1646,
search results 3:2 3840x2560, universal 16:9 5244x2950 PNG. No alpha.

Usage:  python compose.py [snaps_dir] [out_dir]
"""
import sys
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter, ImageFont

SNAPS = Path(sys.argv[1] if len(sys.argv) > 1 else "/private/tmp/tailspot_snaps/marketing")
OUT = Path(sys.argv[2] if len(sys.argv) > 2 else Path(__file__).parent / "out")
FONT_BOLD = "/Library/Fonts/SF-Pro-Display-Bold.otf"
FONT_MED = "/Library/Fonts/SF-Pro-Display-Medium.otf"
SYSTEM_SF = "/System/Library/Fonts/SFNS.ttf"   # variable SF, present on every Mac


def font(path, size, weight):
    """SF Pro Display when Apple's installer has been run; otherwise the
    system's variable SF at the matching weight (same family, same metrics
    to within a pixel or two)."""
    try:
        return ImageFont.truetype(path, size)
    except OSError:
        f = ImageFont.truetype(SYSTEM_SF, size)
        try:
            f.set_variation_by_name(weight)
        except Exception:
            pass
        return f

# The deck's "tailspot-dusk" gradient (constants.ts bgGradient).
STOPS = [(0.0, (0x0A, 0x12, 0x26)), (0.62, (0x17, 0x21, 0x3D)), (1.0, (0x3B, 0x30, 0x40))]
INK = (255, 255, 255)
MUTED = (0xB4, 0xBE, 0xD4)
CYAN = (0x00, 0xD4, 0xFF)


def gradient(w, h):
    col = Image.new("RGB", (1, h))
    px = col.load()
    for y in range(h):
        t = y / (h - 1)
        for (t0, c0), (t1, c1) in zip(STOPS, STOPS[1:]):
            if t0 <= t <= t1:
                k = (t - t0) / (t1 - t0)
                px[0, y] = tuple(round(a + (b - a) * k) for a, b in zip(c0, c1))
                break
    return col.resize((w, h)).convert("RGBA")


def card(name, height):
    im = Image.open(SNAPS / f"part_card_{name}.png").convert("RGBA")
    im = im.crop(im.getchannel("A").point(lambda a: 255 if a > 8 else 0).getbbox())
    return im.resize((round(im.width * height / im.height), height), Image.LANCZOS)


def phone(height):
    """The HUD render inside a plain dark bezel (no device brand mark)."""
    screen = Image.open(SNAPS / "mkt_01_fleet_week.png").convert("RGBA")
    bezel = round(height * 0.018)
    sh = height - 2 * bezel
    sw = round(screen.width * sh / screen.height)
    screen = screen.resize((sw, sh), Image.LANCZOS)
    r_screen = round(sw * 0.145)
    mask = Image.new("L", (sw, sh), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, sw - 1, sh - 1), r_screen, fill=255)
    body = Image.new("RGBA", (sw + 2 * bezel, height), (0, 0, 0, 0))
    ImageDraw.Draw(body).rounded_rectangle(
        (0, 0, body.width - 1, height - 1), r_screen + bezel, fill=(14, 16, 22, 255),
        outline=(70, 76, 92, 255), width=max(2, bezel // 6))
    body.paste(screen, (bezel, bezel), mask)
    return body


def place(canvas, im, cx, cy, angle=0.0, shadow=True):
    if angle:
        im = im.rotate(angle, resample=Image.BICUBIC, expand=True)
    x, y = round(cx - im.width / 2), round(cy - im.height / 2)
    if shadow:
        a = im.getchannel("A")
        blur = max(8, im.height // 28)
        sh = Image.new("RGBA", im.size, (0, 0, 0, 0))
        sh.putalpha(a.point(lambda v: v * 0.55))
        pad = blur * 3
        big = Image.new("RGBA", (im.width + 2 * pad, im.height + 2 * pad), (0, 0, 0, 0))
        big.paste(sh, (pad, pad))
        big = big.filter(ImageFilter.GaussianBlur(blur))
        canvas.alpha_composite(big, (x - pad, y - pad + blur))
    canvas.alpha_composite(im, (x, y))


def text_block(canvas, x, y, lines, size, sub=None, sub_size=None, accent_line=None, width=None):
    d = ImageDraw.Draw(canvas)
    f = font(FONT_BOLD, size, "Bold")
    lh = round(size * 1.08)
    for i, line in enumerate(lines):
        d.text((x, y + i * lh), line, font=f, fill=CYAN if i == accent_line else INK)
    y_end = y + len(lines) * lh
    if sub:
        fs = font(FONT_MED, sub_size, "Medium")
        rows = wrap(sub, fs, width)
        sy = y_end + round(size * 0.45)
        for i, r in enumerate(rows):
            d.text((x, sy + i * round(sub_size * 1.35)), r, font=fs, fill=MUTED)
        y_end = sy + len(rows) * round(sub_size * 1.35)
    return y_end


def wrap(text, f, width):
    d = ImageDraw.Draw(Image.new("RGB", (1, 1)))
    row, rows = "", []
    for w in text.split():
        trial = (row + " " + w).strip()
        if width and d.textlength(trial, font=f) > width:
            rows.append(row); row = w
        else:
            row = trial
    rows.append(row)
    return rows


def text_height(lines, size, sub, sub_size, width):
    """Height of the block text_block will draw, from the rows the subline
    actually wraps to (so editing the copy can't knock it off-centre)."""
    rows = len(wrap(sub, font(FONT_MED, sub_size, "Medium"), width))
    return len(lines) * round(size * 1.08) + round(size * 0.45) + rows * round(sub_size * 1.35)


def header():
    """Headline + the airshow trio, laid out as ONE group centred in the
    frame. On iPhone the product page shows a 16:9 centre crop of this 21:9
    image (about 2926 of the 3840 px; ~457 px fall off each side), with the
    back / share buttons over the top corners. So the group is scaled to fit
    inside that crop with a margin. No subline: at header scale it was too
    small to read (Noah, 2026-10-12)."""
    W, H = 3840, 1646
    crop_w = H * 16 / 9                 # what an iPhone actually shows
    max_group_w = crop_w - 2 * 170      # keep a margin inside the crop
    c = gradient(W, H)
    lines = ["Catch the planes", "flying overhead."]

    def layout(k):
        size = round(150 * k)
        f = font(FONT_BOLD, size, "Bold")
        text_w = max(ImageDraw.Draw(c).textlength(l, font=f) for l in lines)
        gap, spread, tilt = 130 * k, 530 * k, 8
        t33, l39, t6 = card("t33", round(1180 * k)), card("l39", round(1360 * k)), card("t6", round(1180 * k))
        left = -spread - t33.rotate(tilt, expand=True).width / 2
        right = spread + t6.rotate(-tilt, expand=True).width / 2
        return size, text_w, gap, spread, tilt, (t33, l39, t6), left, right, text_w + gap + right - left

    k = 1.0
    while True:
        size, text_w, gap, spread, tilt, (t33, l39, t6), left, right, group_w = layout(k)
        if group_w <= max_group_w or k < 0.5:
            break
        k -= 0.02
    x0 = (W - group_w) / 2
    front_cx = x0 + text_w + gap - left

    th = len(lines) * round(size * 1.08)
    text_block(c, round(x0), (H - th) // 2, lines, size, accent_line=1)
    place(c, t33, front_cx - spread, H / 2 + 37 * k, angle=tilt)
    place(c, t6, front_cx + spread, H / 2 + 37 * k, angle=-tilt)
    place(c, l39, front_cx, H / 2)
    return c


def phone_and_card(W, H, scale, text_x, phone_cx, card_cx, card_h=0.70):
    c = gradient(W, H)
    lines = ["Point at the sky.", "Catch real planes."]
    # No subline: too small to read at search-results scale (Noah, 2026-10-12).
    size = round(170 * scale)
    th = len(lines) * round(size * 1.08)
    text_block(c, text_x, (H - th) // 2, lines, size, accent_line=1)
    p = phone(round(H * 0.86))
    place(c, p, phone_cx, H // 2)
    place(c, card("e6", round(H * card_h)), card_cx, round(H * 0.54), angle=-6)
    return c


def search():
    # 3:2 is narrower than the universal 16:9: smaller type, phone and card
    # pulled in so the headline clears the phone and the card stays on canvas.
    return phone_and_card(3840, 2560, 0.88, 240, 2300, 3130, card_h=0.62)


def universal():
    return phone_and_card(5244, 2950, 1.2, 420, 3000, 4330)


if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    for name, fn, size in [("header_21x9_3840x1646", header, (3840, 1646)),
                           ("search_3x2_3840x2560", search, (3840, 2560)),
                           ("universal_16x9_5244x2950", universal, (5244, 2950))]:
        im = fn().convert("RGB")  # App Store rejects alpha
        assert im.size == size, (name, im.size)
        im.save(OUT / f"{name}.png", optimize=True)
        print("wrote", OUT / f"{name}.png", im.size)
