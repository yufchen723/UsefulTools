#!/usr/bin/env python3
"""Crop the article header (the reader's cover) out of a publisher-page screenshot.

Usage: python3 crop_cover.py <screenshot> <out.png> --rect LEFT TOP RIGHT BOTTOM --vw <innerWidth> [--pad 16] [--pad-top 0]

LEFT/TOP/RIGHT/BOTTOM are CSS pixels in the viewport (getBoundingClientRect, measured with the page
scrolled exactly as in the screenshot); --vw is window.innerWidth. The screenshot may be any scale:
coordinates are mapped by image width / innerWidth. Take the screenshot at full scale for a sharp cover.
"""
import argparse
from PIL import Image

ap = argparse.ArgumentParser()
ap.add_argument("shot"); ap.add_argument("out")
ap.add_argument("--rect", nargs=4, type=float, required=True)
ap.add_argument("--vw", type=float, required=True); ap.add_argument("--pad", type=float, default=16)
ap.add_argument("--pad-top", type=float, default=0, help="padding above TOP (0 = start exactly at the masthead)")
a = ap.parse_args()
im = Image.open(a.shot).convert("RGB")
k = im.width / a.vw                      # image pixels per CSS pixel
l, t, r, b = [v * k for v in a.rect]; p = a.pad * k; pt = a.pad_top * k
box = (max(0, int(l - p)), max(0, int(t - pt)), min(im.width, int(r + p)), min(im.height, int(b + p)))
out = im.crop(box); out.save(a.out, optimize=True)
print(a.out, out.size)
