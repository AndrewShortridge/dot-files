"""copy_mode_images - the kitty half of images in copy mode.

Runs inside the kitty process, over the copy-mode overlay; answers about the
window underneath it. scripts/copy-mode.lua calls it with `kitten @ kitten`:

    list
        Where every image placement sits in the window's scrollback + screen.
    plain IMAGE SHOWN_WIDTH SHOWN_HEIGHT SRC_LEFT SRC_TOP SRC_RIGHT SRC_BOTTOM PATH
        Write to PATH the pixels a placement shows of the image with internal
        id IMAGE. The numbers are that placement's `px` and `src` from `list`.
    placeholder CLIENT_ID PATH
        Write to PATH the pixels of the image a program sent under CLIENT_ID.

Each prints one JSON object. Pixels are written raw (RGB or RGBA), which is
how kitty holds them.

kitty has no API for any of this. The calls below are the hooks its own test
suite uses (GraphicsManager.update_layers, .image_for_client_id, .disk_cache);
their meaning is taken from kitty/graphics.c at v0.51.0.
"""

import json
import math
import struct

from kittens.tui.handler import result_handler
from kitty.fast_data_types import cell_size_for_window

# kitty's cache holds a frame of an image under (internal image id, frame id);
# graphics.c cache_key(). The first frame of an image has frame id 1, more if
# the image was sent again under the same id.
_MAX_ROOT_FRAME_ID = 16


def main(args):
    pass


def placements(screen, cell_width, cell_height):
    """Every image placement in the screen and its scrollback.

    kitty only says where placements are for a viewport, in the coordinates it
    draws with: ask for one viewport after another, from the screen up to the
    top of the scrollback.
    """
    grman = screen.grman
    lines, columns = screen.lines, screen.columns
    dx, dy = 2.0 / columns, 2.0 / lines
    history = screen.historybuf.count

    found = {}
    for scrolled_by in sorted({min(offset, history) for offset in range(0, history + lines, lines)}):
        for layer in grman.update_layers(scrolled_by, -1.0, 1.0, dx, dy, columns, lines, cell_width, cell_height):
            key = (layer['image_id'], layer['ref_id'])
            if key in found or layer['indexed_px_sz']:
                continue
            dest, src = layer['dest_rect'], layer['src_rect']
            top = (1.0 - dest['top']) / dy
            left = (dest['left'] + 1.0) / dx
            height = (dest['top'] - dest['bottom']) / dy
            width = (dest['right'] - dest['left']) / dx
            top_row = math.floor(top + 1e-3)
            left_column = math.floor(left + 1e-3)
            found[key] = {
                'image': layer['image_id'],
                'ref': layer['ref_id'],
                # Rows from the placement's first row to the last row of the
                # screen, both included: the snapshot ends on that row too.
                'rows_before_end': lines + scrolled_by - top_row,
                'column': left_column + 1,
                'rows': max(1, math.ceil(top + height - 1e-3) - top_row),
                'columns': max(1, math.ceil(left + width - 1e-3) - left_column),
                'z_index': layer['z_index'],
                'src': [src['left'], src['top'], src['right'], src['bottom']],
                'px': [width * cell_width, height * cell_height],
            }

    # The sweep left kitty's draw list on some other viewport. kitty rebuilds
    # the list when the scroll offset it is asked for differs from the last
    # one; make sure it differs.
    grman.update_layers(screen.scrolled_by + 1, -1.0, 1.0, dx, dy, columns, lines, cell_width, cell_height)
    return sorted(found.values(), key=lambda p: (-p['rows_before_end'], p['column']))


def cached_pixels(grman, image):
    """The pixels of the first frame of an image, by its internal id."""
    for frame in range(1, _MAX_ROOT_FRAME_ID + 1):
        try:
            return grman.disk_cache.get(struct.pack('=QI', image, frame))
        except KeyError:
            continue
    return None


def dimensions(byte_count, shown_width, shown_height, src):
    """Width, height and bytes per pixel of an image, from its size in bytes.

    kitty hands out the pixels of an image nobody gave an id without saying
    how wide it is. A placement that shows the image unscaled gives the exact
    size (shown_* are its pixels on screen, src the part of the image shown).
    Otherwise take the divisor pair of the pixel count whose shape is nearest
    the shape on screen; `guessed` says that happened.
    """
    span_x, span_y = src[2] - src[0], src[3] - src[1]
    if span_x <= 0 or span_y <= 0:
        return None
    full_width, full_height = shown_width / span_x, shown_height / span_y

    width, height = round(full_width), round(full_height)
    for depth in (4, 3):
        if width > 0 and height > 0 and width * height * depth == byte_count:
            return {'width': width, 'height': height, 'depth': depth, 'guessed': False}

    aspect = full_width / full_height
    best = None
    for depth in (4, 3):
        if byte_count % depth:
            continue
        pixels = byte_count // depth
        for a in range(1, math.isqrt(pixels) + 1):
            if pixels % a:
                continue
            for width, height in ((a, pixels // a), (pixels // a, a)):
                error = abs(math.log(width / height / aspect))
                if best is None or error < best[0]:
                    best = (error, width, height, depth)
    if best is None or best[0] > math.log(1.15):
        return None
    return {'width': best[1], 'height': best[2], 'depth': best[3], 'guessed': True}


def write_plain(screen, image, shown_width, shown_height, src, path):
    """Write the part of an image a placement shows."""
    data = cached_pixels(screen.grman, image)
    if data is None:
        return {'error': 'no pixels cached for this image'}
    size = dimensions(len(data), shown_width, shown_height, src)
    if size is None:
        return {'error': f'cannot tell the size of the image from {len(data)} bytes'}

    # A placement made of placeholder cells always shows a whole image, so
    # one that showed part of its image gets that part as an image of its own.
    width, height, depth = size['width'], size['height'], size['depth']
    left, right = round(src[0] * width), round(src[2] * width)
    top, bottom = round(src[1] * height), round(src[3] * height)
    if (left, top, right, bottom) != (0, 0, width, height):
        stride = width * depth
        data = b''.join(data[y * stride + left * depth:y * stride + right * depth] for y in range(top, bottom))
        size = dict(size, width=right - left, height=bottom - top)

    with open(path, 'wb') as f:
        f.write(data)
    return dict(size, path=path)


def write_placeholder(screen, client_id, path):
    image = screen.grman.image_for_client_id(client_id)
    if not image or not image['data']:
        return {'error': 'the window has no image with this id'}
    width, height, data = image['width'], image['height'], image['data']
    with open(path, 'wb') as f:
        f.write(data)
    return {'width': width, 'height': height, 'depth': len(data) // (width * height), 'guessed': False, 'path': path}


@result_handler(no_ui=True)
def handle_result(args, answer, target_window_id, boss):
    window = boss.window_id_map.get(target_window_id)
    if window is None:
        return json.dumps({'error': 'no such window'})
    window = window.overlay_parent or window
    screen = window.screen
    command, rest = args[1], args[2:]

    if command == 'list':
        cell_width, cell_height = cell_size_for_window(window.os_window_id)
        return json.dumps({
            'window': window.id,
            'lines': screen.lines,
            'columns': screen.columns,
            'history': screen.historybuf.count,
            'cell': [cell_width, cell_height],
            'placements': placements(screen, cell_width, cell_height),
        })
    if command == 'plain':
        image, numbers, path = int(rest[0]), [float(n) for n in rest[1:7]], rest[7]
        return json.dumps(write_plain(screen, image, numbers[0], numbers[1], numbers[2:], path))
    if command == 'placeholder':
        return json.dumps(write_placeholder(screen, int(rest[0]), rest[1]))
    return json.dumps({'error': f'unknown command: {command}'})
