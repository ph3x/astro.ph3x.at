#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCES_DIR="$SCRIPT_DIR/sources"
CONTENT_DIR="$SCRIPT_DIR/content"
R2_BUCKET="astro-ph3x-at-images"
R2_PUBLIC_BASE="https://images.astro.ph3x.at"

# Check dependencies
for cmd in magick wrangler python3; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "❌ Required command not found: $cmd"; exit 1; }
done

if [ ! -d "$SOURCES_DIR" ]; then
    echo "✨ No sources/ directory found, nothing to do."
    exit 0
fi

found=0

while IFS= read -r -d '' tif; do
    rel="${tif#"$SOURCES_DIR"/}"
    dir="$(dirname "$rel")"
    filename="$(basename "$rel")"
    name="${filename%.*}"

    webp_path="$CONTENT_DIR/$dir/${name}.webp"

    # Skip already processed
    if [ -f "$webp_path" ]; then
        continue
    fi

    found=1
    echo "🔭 Processing: $rel"

    mkdir -p "$CONTENT_DIR/$dir"

    # Convert TIFF → WebP
    echo "   Converting to WebP (max 3000px, quality 85)..."
    magick "$tif" -auto-orient -resize "3000x3000>" -quality 85 -define webp:lossless=false "$webp_path"
    size=$(du -sh "$webp_path" | cut -f1)
    echo "   Output: $webp_path ($size)"

    # Upload original TIFF to R2
    r2_key="$rel"
    echo "   Uploading original to R2..."
    wrangler r2 object put "$R2_BUCKET/$r2_key" --file="$tif" --remote 2>&1 | grep -E "Upload|Error|complete" || true
    r2url="$R2_PUBLIC_BASE/$r2_key"

    # Read optional sidecar caption
    sidecar="$(dirname "$tif")/${name}.yaml"
    image_title=""
    if [ -f "$sidecar" ]; then
        image_title="$(python3 -c "
import sys, re
content = open('$sidecar').read()
m = re.search(r'^title:\s*[\"\'']?(.*?)[\"\'']?\s*$', content, re.MULTILINE)
print(m.group(1).strip('\"\'') if m else '')
")"
        [ -n "$image_title" ] && echo "   Caption: $image_title"
    fi

    # Update index.md
    index_md="$CONTENT_DIR/$dir/index.md"
    section_title="$(basename "$dir" | sed 's/-/ /g' | python3 -c "import sys; print(sys.stdin.read().strip().title())")"

    WEBP_NAME="${name}.webp" \
    R2URL="$r2url" \
    INDEX_MD="$index_md" \
    SECTION_TITLE="$section_title" \
    IMAGE_TITLE="$image_title" \
    python3 - << 'PYTHON'
import os, re, sys

index_path  = os.environ["INDEX_MD"]
webp_name   = os.environ["WEBP_NAME"]
r2url       = os.environ["R2URL"]
title       = os.environ["SECTION_TITLE"]
image_title = os.environ["IMAGE_TITLE"]

new_resource = (
    f'  - src: {webp_name}\n'
    f'    title: "{image_title}"\n'
    f'    params:\n'
    f'      r2url: "{r2url}"'
)

if not os.path.exists(index_path):
    with open(index_path, "w") as f:
        f.write(f"---\ntitle: {title}\nresources:\n{new_resource}\n---\n")
    print(f"   Created: {index_path}")
    sys.exit(0)

with open(index_path, "r") as f:
    content = f.read()

if webp_name in content:
    print(f"   Already in index.md, skipping.")
    sys.exit(0)

fm_match = re.match(r"^(---\n)(.*?)(\n---)(.*)", content, re.DOTALL)
if not fm_match:
    print(f"   ⚠️  Could not parse front matter in {index_path}")
    sys.exit(1)

pre, fm, sep, body = fm_match.groups()

if "resources:" in fm:
    fm = fm.rstrip() + "\n" + new_resource
else:
    fm = fm.rstrip() + "\nresources:\n" + new_resource

with open(index_path, "w") as f:
    f.write(pre + fm + sep + body)

print(f"   Updated: {index_path}")
PYTHON

    echo "   ✅ Done — R2: $r2url"
    [ -z "$image_title" ] && echo "   ✏️  No sidecar found — set caption manually in: $index_md"
    echo ""

done < <(find "$SOURCES_DIR" -type f \( -iname "*.tif" -o -iname "*.tiff" \) -print0 2>/dev/null)

if [ "$found" -eq 0 ]; then
    echo "✨ No new images to process."
fi
