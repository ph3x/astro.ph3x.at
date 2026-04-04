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
    sidecar="$(dirname "$tif")/${name}.yaml"
    index_md="$CONTENT_DIR/$dir/index.md"

    # Determine what needs doing
    needs_convert=false
    needs_title_update=false

    if [ ! -f "$webp_path" ]; then
        needs_convert=true
    elif [ "$tif" -nt "$webp_path" ]; then
        echo "🔄 TIFF changed, re-processing: $rel"
        needs_convert=true
    fi

    if [ -f "$sidecar" ] && [ "$sidecar" -nt "$webp_path" ] && [ "$needs_convert" = false ]; then
        needs_title_update=true
    fi

    [ "$needs_convert" = false ] && [ "$needs_title_update" = false ] && continue

    found=1

    # Read optional sidecar caption
    image_title=""
    if [ -f "$sidecar" ]; then
        image_title="$(grep '^title:' "$sidecar" | head -1 | sed 's/^title:[[:space:]]*//' | sed "s/^[\"']//; s/[\"'][[:space:]]*$//")"
    fi

    if [ "$needs_convert" = true ]; then
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
    else
        r2url="$R2_PUBLIC_BASE/$rel"
        echo "✏️  Updating caption: $rel"
    fi

    [ -n "$image_title" ] && echo "   Caption: $image_title"

    # Update index.md (add or update resource entry)
    section_title="$(basename "$dir" | sed 's/-/ /g' | python3 -c "import sys; print(sys.stdin.read().strip().title())")"

    WEBP_NAME="${name}.webp" \
    R2URL="$r2url" \
    INDEX_MD="$index_md" \
    SECTION_TITLE="$section_title" \
    IMAGE_TITLE="$image_title" \
    NEEDS_CONVERT="$needs_convert" \
    python3 - << 'PYTHON'
import os, re, sys

index_path    = os.environ["INDEX_MD"]
webp_name     = os.environ["WEBP_NAME"]
r2url         = os.environ["R2URL"]
title         = os.environ["SECTION_TITLE"]
image_title   = os.environ["IMAGE_TITLE"]
needs_convert = os.environ["NEEDS_CONVERT"] == "true"

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

fm_match = re.match(r"^(---\n)(.*?)(\n---)(.*)", content, re.DOTALL)
if not fm_match:
    print(f"   ⚠️  Could not parse front matter in {index_path}")
    sys.exit(1)

pre, fm, sep, body = fm_match.groups()

if webp_name in fm:
    # Update existing entry's title in place
    fm = re.sub(
        rf'(  - src: {re.escape(webp_name)}\n    title: ")[^"]*(")',
        rf'\g<1>{image_title}\g<2>',
        fm
    )
    print(f"   Updated title in: {index_path}")
elif needs_convert:
    # Add new resource entry
    if "resources:" in fm:
        fm = fm.rstrip() + "\n" + new_resource
    else:
        fm = fm.rstrip() + "\nresources:\n" + new_resource
    print(f"   Updated: {index_path}")

with open(index_path, "w") as f:
    f.write(pre + fm + sep + body)
PYTHON

    # Stage the produced files
    git -C "$SCRIPT_DIR" add "$webp_path" "$index_md"

    if [ "$needs_convert" = true ]; then
        echo "   ✅ Done — R2: $r2url"
        [ -z "$image_title" ] && echo "   ✏️  No sidecar found — set caption manually in: $index_md"
    else
        echo "   ✅ Caption updated"
    fi
    echo ""

done < <(find "$SOURCES_DIR" -type f \( -iname "*.tif" -o -iname "*.tiff" \) -print0 2>/dev/null)

if [ "$found" -eq 0 ]; then
    echo "✨ No new or changed images to process."
fi
