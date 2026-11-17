#!/usr/bin/env python3
"""Compare offscreen GPU exports to cropped reference frames (Pillow + NumPy).
Run: python3 tools/compare-glow.py build/glow-validation iteration-1
The temporal-minimum background is an estimate, not a clean original desktop.
Metrics describe appearance distributions, not pixel-perfect or beat alignment.
"""
import json
import sys
from pathlib import Path
import numpy as np
from PIL import Image, ImageDraw

root = Path(sys.argv[1])
variant = sys.argv[2] if len(sys.argv) > 2 else 'after'
reference_paths = sorted((root / 'reference').glob('frame-*.png'))[:140]
reference = np.stack([np.array(Image.open(p).convert('RGB')) for p in reference_paths])
background = np.percentile(reference, 5, axis=0).astype(np.uint8)
Image.fromarray(background).save(root / 'estimated-background.png')
height, width = background.shape[:2]
y, x = np.indices((height, width))
distance = np.minimum.reduce([x, y, width-1-x, height-1-y])
mask = (distance < 45) & (x > 20) & (x < width-20) | ((distance < 45) & (y > 20) & (y < height-20))

def composite(folder):
    frames = []
    for path in sorted((root / folder).glob('frame-*.png'))[:len(reference)]:
        canvas = Image.fromarray(background).convert('RGBA')
        canvas.alpha_composite(Image.open(path).convert('RGBA'))
        frames.append(np.array(canvas.convert('RGB')))
    return np.stack(frames)

def strips(frames, depth):
    blue = np.maximum(0, frames[..., 2].astype(np.float32) - frames[..., 0])
    return np.concatenate([blue[:,depth,20:width-20], blue[:,20:height-20,width-1-depth],
        blue[:,height-1-depth,20:width-20][:,::-1], blue[:,20:height-20,depth][:,::-1]], axis=1)

def summarize(frames):
    edge = np.max([strips(frames, d) for d in range(5)], axis=0)
    # Near-black bottom wallpaper permits useful colour/falloff estimates. The
    # menu bar, compression, motion and browser scaling still bias these numbers.
    bottom = frames[:,height-16:height,20:width-20].astype(float)
    active = (bottom[...,2] - bottom[...,0]) > 120
    bottom_rgb = np.median(bottom[active], axis=0) if active.any() else [0,0,0]
    small = np.stack([edge[:,i:i+8].mean(axis=1) for i in range(0,edge.shape[1]-8,8)],axis=1)
    def linear(rgb):
        rgb = rgb.astype(np.float32) / 255
        return np.where(rgb <= 0.04045, rgb / 12.92, ((rgb + 0.055) / 1.055)**2.4)
    residual = np.maximum(0, linear(frames[:,mask]) - linear(background[mask])[None])
    luminance = residual @ np.array([0.2126,0.7152,0.0722], dtype=np.float32)
    # This static, near-black strip is less biased by the changing menu-bar wallpaper.
    bottom_delta = linear(frames[:,height-30:,40:width-40]) - linear(background[height-30:,40:width-40])[None]
    bottom_luminance = np.maximum(0, bottom_delta @ np.array([0.2126,0.7152,0.0722], dtype=np.float32))
    return {
        'edge_blue_excess_quantiles_10_50_90': np.percentile(edge, [10,50,90]).round(2).tolist(),
        'dark_perimeter_fraction_blue_excess_below_20': round(float(np.mean(edge<20)),4),
        'bright_perimeter_fraction_blue_excess_above_100': round(float(np.mean(edge>100)),4),
        'bright_bottom_RGB_median': np.asarray(bottom_rgb).round(1).tolist(),
        'blue_excess_depth_p95': {str(d): round(float(np.percentile(strips(frames,d),95)),1) for d in [0,2,4,8,12,16,20,30,40]},
        'perimeter_temporal_change_mean_per_125ms': round(float(np.abs(np.diff(small,axis=0)).mean()),2),
        'estimated_added_linear_luminance_mean_p95': np.array([luminance.mean(), np.percentile(luminance,95)]).round(5).tolist(),
        'dark_bottom_added_linear_luminance_mean_p95': np.array([bottom_luminance.mean(), np.percentile(bottom_luminance,95)]).round(5).tolist(),
        'border_RGB_MAE_vs_reference_unaligned': round(float(np.abs(frames[:,mask].astype(np.float32)-reference[:len(frames),mask].astype(np.float32)).mean()),2)
    }, small

sets = {'reference': reference, 'before': composite('before'), variant: composite(variant)}
results = {}
for name, frames in sets.items():
    results[name], motion = summarize(frames)
    im = Image.fromarray(np.uint8(np.clip(motion/220*255,0,255))).resize((1200,400))
    im.save(root / f'{name}-motion.png')
    results[name]['limitations'] = 'Browser-compressed crop; estimated background; phase unaligned; no source audio/notch.'
with open(root / f'{variant}-metrics.json','w') as out:
    json.dump(results,out,indent=2)
print(json.dumps(results,indent=2))
# Use identical estimated backgrounds and dimensions for the side-by-side evidence.
thumb_width=570
thumb_height=round(height*thumb_width/width)
sheet=Image.new('RGB',(thumb_width*3,(thumb_height+30)*4),(18,18,20))
draw=ImageDraw.Draw(sheet)
for row,frame_index in enumerate([0,16,64,112]):
    for col,(name,frames) in enumerate(sets.items()):
        im=Image.fromarray(frames[frame_index]).resize((thumb_width,thumb_height))
        xx=col*thumb_width; yy=row*(thumb_height+30)
        draw.text((xx+10,yy+8),f'{name} | {frame_index/8:.1f}s',fill='white')
        sheet.paste(im,(xx,yy+30))
sheet.save(root / f'{variant}-comparison.jpg',quality=95)
# Composited production renders for the motion preview.
outdir=root / f'{variant}-composite'; outdir.mkdir(exist_ok=True)
for i,frame in enumerate(sets[variant]):
    Image.fromarray(frame).save(outdir / f'frame-{i+1:03d}.png', compress_level=1)
