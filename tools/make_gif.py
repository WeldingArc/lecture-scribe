# Assembles a README GIF from frames rendered by tools/frames.swift: crops to the card (found automatically) and
# uses one shared palette that keeps the small accent colours.
# usage: python3 tools/make_gif.py <frames-dir> <out.gif> <width> [speed]
# (frames rendered at 10 fps of the page's own clock; speed plays them faster — the slide demo's DEMO_SPEED is 1.75)
import glob, sys
from collections import Counter
from PIL import Image, ImageChops
src, out, width = sys.argv[1], sys.argv[2], int(sys.argv[3])
speed = float(sys.argv[4]) if len(sys.argv) > 4 else 1.0
files = sorted(glob.glob(src + "/*.png"))
frames = [Image.open(f).convert("RGB") for f in files]
bg = frames[len(frames) // 2].getpixel((4, 4))
box = None
for im in frames[10::15]:                                   # union of the card's extent over the story
    diff = ImageChops.difference(im, Image.new("RGB", im.size, bg)).convert("L").point(lambda v: 255 if v > 10 else 0)
    b = diff.getbbox()
    box = b if box is None else (min(box[0], b[0]), min(box[1], b[1]), max(box[2], b[2]), max(box[3], b[3]))
m = 16
box = (max(0, box[0] - m), max(0, box[1] - m), min(frames[0].width, box[2] + m), min(frames[0].height, box[3] + m))
h = round((box[3] - box[1]) * width / (box[2] - box[0]))
small = [im.crop(box).resize((width, h), Image.LANCZOS) for im in frames]
picks = list(range(15, len(small), max(1, len(small) // 12)))[:12]
sheet = Image.new("RGB", (width, h * len(picks) + 120))
for j, k in enumerate(picks): sheet.paste(small[k], (0, j * h))
# small but important colours (the accent, the cameras) get a swatch so the palette keeps them
cnt = Counter()
for k in picks:
    for c, n in Counter(small[k].get_flattened_data() if hasattr(small[k], 'get_flattened_data') else small[k].getdata()).items():
        r, g, b = c
        if max(r, g, b) - min(r, g, b) > 40: cnt[(r // 8 * 8, g // 8 * 8, b // 8 * 8)] += n
vivid = [c for c, _ in cnt.most_common(48)]
for j, c in enumerate(vivid):
    sheet.paste(Image.new("RGB", (width // 12, 40), c), ((j % 12) * (width // 12), h * len(picks) + (j // 12) * 30))
pal = sheet.quantize(colors=160, method=Image.Quantize.MEDIANCUT)
q = [im.quantize(palette=pal, dither=Image.Dither.NONE) for im in small]
ends = [round((k + 1) * 10 / speed) for k in range(len(q))]          # GIF delays are centiseconds: rounded so the total stays exact
durations = [10 * (e - b) for b, e in zip([0] + ends[:-1], ends)]
q[0].save(out, save_all=True, append_images=q[1:], duration=durations, loop=0, optimize=False)
print("crop", box, "->", (width, h), len(q), "frames")
