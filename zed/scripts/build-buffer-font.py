#!/usr/bin/env python3
"""Build the editor font family for Zed out of the four faces kitty.conf names.

Zed takes one family for the editor (`buffer_font_family`) and picks the bold
and italic faces from inside it; it has no setting for a separate italic font.
kitty.conf mixes two families: JetBrainsMono for regular and bold, VictorMono
(cursive) for italic and bold italic. This writes those four faces out under
one family name, so Zed draws what kitty draws.

The two families do not share a cell. JetBrainsMono is 600 units wide on a
1000-unit em, VictorMono 600 on 1100, so at one font size a VictorMono glyph is
narrower. kitty puts every glyph in the cell of the regular font; here the
italic faces get the regular face's advance and line metrics (in em), which
keeps columns aligned and the baseline where it is. No outline is changed.

Run again after updating either Nerd Font: python3 build-buffer-font.py
Needs fontTools and fontconfig (fc-match, fc-cache).
"""

import os
import subprocess
import sys

from fontTools.ttLib import TTFont

FAMILY = "JetBrainsVictorMono Nerd Font"

# (style name, fontconfig pattern of the source face, weight, bold, italic).
# The patterns are kitty.conf's font_family / bold_font / italic_font /
# bold_italic_font. The italic is VictorMono's SemiBold: it is the face used
# for italic text at the regular weight, so it is written out as weight 400.
FACES = [
    ("Regular", "JetBrainsMono Nerd Font:style=Regular", 400, False, False),
    ("Bold", "JetBrainsMono Nerd Font:style=Bold", 700, True, False),
    ("Italic", "VictorMono Nerd Font:style=SemiBold Italic", 400, False, True),
    ("Bold Italic", "VictorMono Nerd Font:style=Bold Italic", 700, True, True),
]

REPLACED_NAME_IDS = (1, 2, 3, 4, 6, 16, 17, 21, 22)
FS_SELECTION_ITALIC = 1 << 0
FS_SELECTION_BOLD = 1 << 5
FS_SELECTION_REGULAR = 1 << 6
MAC_STYLE_BOLD = 1 << 0
MAC_STYLE_ITALIC = 1 << 1


def source_path(pattern):
    """The file fontconfig resolves `pattern` to, or exit if it substituted."""
    wanted_family = pattern.split(":")[0]
    wanted_style = pattern.split("style=")[1]
    found = subprocess.run(
        ["fc-match", "--format", "%{file}\n%{family}\n%{style}", pattern],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.split("\n")
    path, families, styles = found[0], found[1].split(","), found[2].split(",")
    if wanted_family not in families or wanted_style not in styles:
        sys.exit(f"not installed: {pattern} (fontconfig offered {path})")
    return path


def cell_advance(font):
    return font["hmtx"].metrics["space"][0]


def fit_to_cell(font, regular):
    """Give `font` the advance and line metrics of `regular`, in em."""
    scale = font["head"].unitsPerEm / regular["head"].unitsPerEm
    advance_scale = cell_advance(regular) * scale / cell_advance(font)

    metrics = font["hmtx"].metrics
    for glyph, (advance, left_bearing) in metrics.items():
        metrics[glyph] = (round(advance * advance_scale), left_bearing)
    font["hhea"].advanceWidthMax = max(advance for advance, _ in metrics.values())
    font["OS/2"].xAvgCharWidth = cell_advance(font)

    for table, fields in (
        ("hhea", ("ascent", "descent", "lineGap")),
        ("OS/2", ("sTypoAscender", "sTypoDescender", "sTypoLineGap", "usWinAscent", "usWinDescent")),
    ):
        for field in fields:
            setattr(font[table], field, round(getattr(regular[table], field) * scale))

    # Per-size advance caches; they would contradict the new advances.
    for table in ("hdmx", "LTSH"):
        if table in font:
            del font[table]


def rename(font, style, weight, bold, italic):
    postscript_name = f"{FAMILY}-{style}".replace(" ", "")
    names = font["name"]
    names.names = [record for record in names.names if record.nameID not in REPLACED_NAME_IDS]
    for name_id, value in (
        (1, FAMILY),
        (2, style),
        (3, f"{postscript_name};built by build-buffer-font.py"),
        (4, f"{FAMILY} {style}"),
        (6, postscript_name),
    ):
        names.setName(value, name_id, 3, 1, 0x409)  # Windows, Unicode BMP, en-US
        names.setName(value, name_id, 1, 0, 0)  # Macintosh, Roman, English

    os2 = font["OS/2"]
    os2.usWeightClass = weight
    os2.fsSelection &= ~(FS_SELECTION_ITALIC | FS_SELECTION_BOLD | FS_SELECTION_REGULAR)
    if italic:
        os2.fsSelection |= FS_SELECTION_ITALIC
    if bold:
        os2.fsSelection |= FS_SELECTION_BOLD
    if not (italic or bold):
        os2.fsSelection |= FS_SELECTION_REGULAR
    font["head"].macStyle = (MAC_STYLE_BOLD if bold else 0) | (MAC_STYLE_ITALIC if italic else 0)


def main():
    data_home = os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share")
    output_dir = os.path.join(data_home, "fonts")
    os.makedirs(output_dir, exist_ok=True)

    regular = TTFont(source_path(FACES[0][1]))
    for style, pattern, weight, bold, italic in FACES:
        font = TTFont(source_path(pattern))
        if italic:
            fit_to_cell(font, regular)
        rename(font, style, weight, bold, italic)
        output_path = os.path.join(output_dir, f"{FAMILY}-{style}.ttf".replace(" ", ""))
        font.save(output_path)
        print(output_path)

    subprocess.run(["fc-cache", "--force", output_dir], check=True)


if __name__ == "__main__":
    main()
