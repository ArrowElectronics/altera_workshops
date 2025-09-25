#!/usr/bin/env python3
"""
128x128 BMP -> centered 28x28 RAW FP16 (MNIST-normalized)

- Grayscale, auto-invert if background is white (can disable).
- Crop to foreground bbox, scale longest side to 20 px, center via center-of-mass.
- Normalize with mean=0.1307, std=0.3081.
- Output: 28*28*2 = 1568 bytes, little-endian FP16, row-major.

Usage:
  python bmp128_to_28bin_fp16_centered.py input.bmp output.bin
  [options]
Options:
  --no-auto-invert        Disable auto inversion (assumes black bg / white fg).
  --invert                Force inversion.
  --fg-thresh 0.05        Foreground threshold after inversion (0..1).
  --target 20             Target max side inside 28x28.
  --resample {nearest,bilinear,bicubic,lanczos}
  --strict128             Enforce 128x128 input size.
"""

import argparse
import sys
import numpy as np
from PIL import Image

RESAMPLE = {
    "nearest": Image.NEAREST,
    "bilinear": Image.BILINEAR,
    "bicubic": Image.BICUBIC,
    "lanczos": Image.LANCZOS,
}

def center_of_mass(a):
    m = a.sum()
    if m <= 1e-12:
        # center of 28x28
        return (13.5, 13.5)
    ys, xs = np.indices(a.shape)
    cy = (ys * a).sum() / m
    cx = (xs * a).sum() / m
    return (cy, cx)

def shift_integer(img, dy, dx):
    h, w = img.shape
    out = np.zeros_like(img)
    y0 = max(0, dy); x0 = max(0, dx)
    y1 = min(h, h + dy) if dy < 0 else h
    x1 = min(w, w + dx) if dx < 0 else w
    sy0 = max(0, -dy); sx0 = max(0, -dx)
    sy1 = sy0 + (y1 - y0)
    sx1 = sx0 + (x1 - x0)
    if (y1 - y0) > 0 and (x1 - x0) > 0:
        out[y0:y1, x0:x1] = img[sy0:sy1, sx0:sx1]
    return out

def auto_invert_needed(img01):
    # check border mean (8px border); if bright -> white bg -> invert
    h, w = img01.shape
    b = min(8, h//4, w//4)
    if b <= 0:
        return False
    border = np.concatenate([
        img01[:b, :].ravel(),
        img01[-b:, :].ravel(),
        img01[:, :b].ravel(),
        img01[:, -b:].ravel()
    ])
    return border.mean() > 0.5

def crop_bbox(fg, thresh):
    mask = fg > thresh
    if not mask.any():
        return (0, 0, fg.shape[1], fg.shape[0])  # full image
    ys, xs = np.where(mask)
    x0, x1 = xs.min(), xs.max() + 1
    y0, y1 = ys.min(), ys.max() + 1
    return (x0, y0, x1, y1)

def main():
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("input_bmp")
    ap.add_argument("output_bin")
    ap.add_argument("--no-auto-invert", action="store_true")
    ap.add_argument("--invert", action="store_true")
    ap.add_argument("--fg-thresh", type=float, default=0.05)
    ap.add_argument("--target", type=int, default=20)
    ap.add_argument("--resample", choices=list(RESAMPLE.keys()), default="bilinear")
    ap.add_argument("--strict128", action="store_true")
    args = ap.parse_args()

    try:
        pil = Image.open(args.input_bmp).convert("L")
    except Exception as e:
        print(f"Open failed: {e}", file=sys.stderr)
        sys.exit(1)

    w, h = pil.size
    if args.strict128 and (w != 128 or h != 128):
        print(f"Input size {w}x{h} != 128x128", file=sys.stderr)
        sys.exit(2)

    # To [0,1], where 0=black, 1=white
    img01 = np.asarray(pil, dtype=np.float32) / 255.0

    # Inversion control
    do_invert = args.invert or (not args.no_auto_invert and auto_invert_needed(img01))
    if do_invert:
        img01 = 1.0 - img01  # foreground bright, background dark

    # Crop to foreground bbox using threshold on foreground intensity
    x0, y0, x1, y1 = crop_bbox(img01, args.fg_thresh)
    cropped = img01[y0:y1, x0:x1]
    ch, cw = cropped.shape

    # Scale longest side to target (default 20)
    target = max(1, min(27, int(args.target)))
    scale = target / float(max(ch, cw)) if max(ch, cw) > 0 else 1.0
    new_w = max(1, int(round(cw * scale)))
    new_h = max(1, int(round(ch * scale)))
    resized = np.asarray(
        Image.fromarray((cropped * 255.0).astype(np.uint8), mode="L").resize(
            (new_w, new_h), RESAMPLE[args.resample]
        ),
        dtype=np.float32
    ) / 255.0

    # Paste into 28x28 canvas centered by geometry
    canvas = np.zeros((28, 28), dtype=np.float32)
    top = (28 - new_h) // 2
    left = (28 - new_w) // 2
    canvas[top:top+new_h, left:left+new_w] = resized

    # Center via center-of-mass (integer pixel shift)
    cy, cx = center_of_mass(canvas)
    dy = int(round(13.5 - cy))
    dx = int(round(13.5 - cx))
    canvas = shift_integer(canvas, dy, dx)

    # Normalize with MNIST stats
    mean, std = 0.1307, 0.3081
    norm = (canvas - mean) / std  # float32

    # To little-endian FP16 raw
    out = norm.astype('<f2', copy=False).tobytes(order='C')
    try:
        with open(args.output_bin, 'wb') as f:
            f.write(out)
    except Exception as e:
        print(f"Write failed: {e}", file=sys.stderr)
        sys.exit(3)

if __name__ == "__main__":
    main()