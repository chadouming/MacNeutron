"""Prints W or N for eight pixels of a 1280x720 PPM frame: whether each is white (all channels > 200).

The samples sit in the middle of present_loop's checkerboard squares and gaps as they appear after a 2x upscale
of a 640x360 swap chain. The last two are near the bottom-right, so only a whole-frame upscale gets them right."""
import sys

SAMPLES = [(16, 16), (48, 16), (80, 16), (16, 48), (48, 80), (16, 80), (1232, 656), (1264, 656)]

with open(sys.argv[1], "rb") as f:
    data = f.read()
magic, width, height, maxval, pixels = data.split(maxsplit=4)
width = int(width)
print("".join("W" if min(pixels[(y * width + x) * 3:(y * width + x) * 3 + 3]) > 200 else "N" for x, y in SAMPLES))
