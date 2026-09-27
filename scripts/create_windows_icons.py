#!/usr/bin/env python3
"""Regenerate the Windows Q mark (Pillow is only needed when editing artwork)."""
import argparse
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
SIZES = (16, 20, 24, 32, 40, 48, 64, 96, 128, 256)
INK = (32, 33, 36)


def mark(size, keyline=True, ink=INK):
    # Work in a 100-unit square, with the visible outline optically centred.
    # Oversampling keeps the oval and short rounded tail clean at tray sizes.
    scale = 8
    side = size * scale
    unit = side / 100

    def silhouette(expansion=0):
        mask = Image.new('L', (side, side))
        draw = ImageDraw.Draw(mask)
        outer = (16 - expansion, 10 - expansion, 80 + expansion, 82 + expansion)
        inner = (27 + expansion, 21 + expansion, 69 - expansion, 71 - expansion)
        draw.ellipse(tuple(v * unit for v in outer), fill=255)
        draw.ellipse(tuple(v * unit for v in inner), fill=0)
        start, end = (57, 61), (79, 83)
        radius = 5.5 + expansion
        draw.line(tuple(v * unit for point in (start, end) for v in point),
                  fill=255, width=round(2 * radius * unit))
        for x, y in (start, end):
            draw.ellipse(tuple(v * unit for v in (x-radius, y-radius, x+radius, y+radius)), fill=255)
        return mask

    body = silhouette()
    # A fine neutral keyline lets the fixed shell icon survive dark wallpapers.
    # It follows the strokes, never fills the centre or adds a tile/background.
    result = Image.new('RGBA', (side, side), (*ink, 0))
    if keyline:
        outline = Image.new('RGBA', (side, side), (255, 255, 255, 0))
        outline.putalpha(silhouette(max(2, 75 / size)))
        result = outline
    foreground = Image.new('RGBA', (side, side), (*ink, 0))
    foreground.putalpha(body)
    result = Image.alpha_composite(result, foreground)
    return result.resize((size, size), Image.Resampling.LANCZOS)


def svg():
    # Same oval, tail, stroke widths and keyline as the raster master above.
    return '''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" fill="none">
  <title>Rime Q</title>
  <g stroke="white" stroke-width="15" stroke-linecap="round">
    <ellipse cx="48" cy="46" rx="26.5" ry="30.5"/>
    <path d="M57 61 79 83"/>
  </g>
  <g stroke="#202124" stroke-width="11" stroke-linecap="round">
    <ellipse cx="48" cy="46" rx="26.5" ry="30.5"/>
    <path d="M57 61 79 83"/>
  </g>
</svg>
'''


def xaml():
    # Native UI follows the existing text colour, including high contrast.
    return '''<Viewbox xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation">
  <Canvas Width="100" Height="100">
    <Ellipse Canvas.Left="16" Canvas.Top="10" Width="64" Height="72"
             Stroke="{DynamicResource TextColor}" StrokeThickness="11"/>
    <Path Data="M57,61 L79,83" Stroke="{DynamicResource TextColor}"
          StrokeThickness="11" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
  </Canvas>
</Viewbox>
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='Check committed artwork without writing it')
    args = parser.parse_args()
    frames = [mark(size) for size in SIZES]
    import io
    output = io.BytesIO()
    frames[-1].save(output, format='ICO', sizes=[(s, s) for s in SIZES], append_images=frames[:-1])
    files = {ROOT / 'windows/resources/RimeQ.ico': output.getvalue(),
             ROOT / 'windows/resources/RimeQ.svg': svg().encode(),
             ROOT / 'windows/resources/Brand.xaml': xaml().encode()}
    # Taskbar consumers tint this clean alpha mask; never reuse the app keyline.
    taskbar = [mark(size, keyline=False, ink=(255, 255, 255)) for size in SIZES]
    output = io.BytesIO()
    # .NET Framework's Icon(Stream) needs DIB frames; PNG frames can be misread.
    taskbar[-1].save(output, format='ICO', bitmap_format='bmp', sizes=[(s, s) for s in SIZES], append_images=taskbar[:-1])
    files[ROOT / 'windows/resources/TaskbarQ.ico'] = output.getvalue()
    for path, data in files.items():
        if args.check:
            if path.read_bytes() != data:
                raise SystemExit(f'Artwork differs: {path.relative_to(ROOT)}')
        else:
            path.write_bytes(data)
    print('Windows Q artwork ' + ('verified' if args.check else 'generated') + ': ' + ', '.join(map(str, SIZES)))


if __name__ == '__main__':
    main()
