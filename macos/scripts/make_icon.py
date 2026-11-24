"""Draws the icon of zitto: lanes of a waveform in the colours of the parts, one of them hushed."""
# Run with Pillow installed: python3 macos/scripts/make_icon.py macos/Resources/AppIcon.png
import math
import sys

from PIL import Image, ImageDraw

SIZE, SCALE = 1024, 4  # drawn large, then reduced: smooth edges
S = SIZE * SCALE
BG, EDGE, MUTED = (20, 23, 28), (42, 48, 58), (57, 64, 75)
LANES = [((255, 122, 144), 1.0), ((255, 180, 84), 0.0), ((139, 212, 80), 0.8), ((76, 201, 240), 0.9),
         ((183, 148, 246), 0.7)]  # lead, drums (hushed), bass, guitar, piano

image = Image.new("RGBA", (S, S), (0, 0, 0, 0))
draw = ImageDraw.Draw(image)
# The body of a macOS icon: 824 of 1024, rounded.
margin = 100 * SCALE
draw.rounded_rectangle((margin, margin, S - margin, S - margin), radius=185 * SCALE, fill=BG)

left, right = margin + 90 * SCALE, S - margin - 90 * SCALE
top, bottom = margin + 110 * SCALE, S - margin - 110 * SCALE
lane = (bottom - top) / len(LANES)
bars, gap = 30, 6 * SCALE
width = (right - left - gap * (bars - 1)) / bars
for n, (color, loud) in enumerate(LANES):
    middle = top + lane * (n + 0.5)
    for b in range(bars):
        x = left + b * (width + gap)
        t = b / (bars - 1)
        shape = abs(math.sin(t * math.pi * (2.3 + n * 0.7) + n)) * (0.35 + 0.65 * math.sin(t * math.pi))
        height = max(lane * 0.42 * shape * (loud or 0.7), 6 * SCALE)
        draw.rounded_rectangle((x, middle - height, x + width, middle + height), radius=width / 2,
                               fill=color if loud else MUTED)
# The playhead.
x = left + (right - left) * 0.62
draw.rounded_rectangle((x - 5 * SCALE, top - 30 * SCALE, x + 5 * SCALE, bottom + 30 * SCALE), radius=5 * SCALE,
                       fill=(245, 196, 81))
image.resize((SIZE, SIZE), Image.LANCZOS).save(sys.argv[1])
