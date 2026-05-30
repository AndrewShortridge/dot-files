#!/bin/bash
# Generate ctags for C header files (optional - ctags-lsp does this automatically)
# Uses miniconda-installed universal-ctags
#
# This script is useful for:
# - Pre-generating tags before starting Neovim
# - Troubleshooting ctags output
# - Generating tags for projects without ctags-lsp

# Use miniconda ctags
CTAGS_CMD="${HOME}/miniconda3/bin/ctags"

# Verify ctags is available
if [ ! -x "$CTAGS_CMD" ]; then
    echo "Error: universal-ctags not found at $CTAGS_CMD"
    echo "Install with: conda install -c conda-forge universal-ctags"
    exit 1
fi

# Show ctags version
echo "Using: $($CTAGS_CMD --version | head -1)"

PROJECT_ROOT="${1:-$(pwd)}"
TAGS_FILE="${PROJECT_ROOT}/tags"
CODE_DIR="${PROJECT_ROOT}/code"

if [ ! -d "$CODE_DIR" ]; then
    echo "Warning: code/ directory not found in $PROJECT_ROOT"
    echo "Scanning entire project root instead..."
    CODE_DIR="$PROJECT_ROOT"
fi

echo "Generating tags from: $CODE_DIR"

# Generate tags (ctags-lsp expects 'tags' file by default)
"$CTAGS_CMD" -f "$TAGS_FILE" \
    --languages=C,C++ \
    --kinds-C=+pxdts \
    --kinds-C++=+pxdts \
    --fields=+iaS \
    --extras=+q \
    -R "$CODE_DIR"

if [ $? -eq 0 ]; then
    TAG_COUNT=$(wc -l < "$TAGS_FILE" 2>/dev/null || echo "0")
    echo "Tags generated: $TAGS_FILE ($TAG_COUNT entries)"
else
    echo "Error generating tags"
    exit 1
fi
