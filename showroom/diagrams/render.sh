#!/usr/bin/env bash
# Render the guide's diagrams (self-contained HTML + inline SVG) to PNG with headless Chrome, at 1.25x.
#   showroom/diagrams/render.sh [name ...]   (default: all; writes showroom/content/modules/ROOT/assets/images/<name>.png)
set -euo pipefail
cd "$(dirname "$0")"
CHROME=${CHROME:-"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"}
for f in ${*:-*.html}; do
  n=${f%.html}; n=${n##*/}
  size=$(sed -n 's/.*<svg[^>]* width="\([0-9]*\)" height="\([0-9]*\)".*/\1,\2/p' "$n.html" | head -1)
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1.25 --window-size="$size" \
    --screenshot="../content/modules/ROOT/assets/images/$n.png" "file://$PWD/$n.html" >/dev/null 2>&1
  echo "$n.png ($size at 1.25x)"
done
