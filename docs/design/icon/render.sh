#!/bin/bash
# 用 Google Chrome 无界面模式把 SVG 按目标像素尺寸直接渲染成 PNG，并生成 preview.html 和 explorations.html
set -euo pipefail

CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
ICON_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$ICON_DIR/../../.." && pwd)"
ASSETS="$REPO/TypeWhisper/Resources/Assets.xcassets"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

render() {
  local svg="$1" px="$2" out="$3"
  cat > "$WORK/page.html" <<HTML
<!doctype html><html><head><style>html,body{margin:0;padding:0;background:transparent;overflow:hidden}img{display:block;width:${px}px;height:${px}px}</style></head>
<body><img src="file://$svg"></body></html>
HTML
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --allow-file-access-from-files \
    --default-background-color=00000000 --force-device-scale-factor=1 \
    --window-size="$px,$px" --screenshot="$out" "file://$WORK/page.html" >/dev/null 2>&1
  local w h
  w=$(sips -g pixelWidth "$out" | awk '/pixelWidth/ {print $2}')
  h=$(sips -g pixelHeight "$out" | awk '/pixelHeight/ {print $2}')
  [[ "$w" == "$px" && "$h" == "$px" ]] || { echo "size mismatch for $out: ${w}x${h}" >&2; exit 1; }
  echo "$out ${w}x${h}"
}

uri() { printf 'data:image/png;base64,%s' "$(base64 -i "$1")"; }

ICON="$ICON_DIR/dictum-icon.svg"
ICON_SMALL="$ICON_DIR/dictum-icon-small.svg"
GLYPH="$ICON_DIR/menubar-glyph.svg"
APPICON="$ASSETS/AppIcon.appiconset"
MENUBAR="$ASSETS/MenuBarGlyph.imageset"
EXPLORATIONS=(a-operator-at-desk b-profile-ribbon-mic c-lamp-cone)

render "$ICON_SMALL" 16   "$APPICON/icon_16x16.png"
render "$ICON_SMALL" 32   "$APPICON/icon_16x16@2x.png"
render "$ICON_SMALL" 32   "$APPICON/icon_32x32.png"
render "$ICON"       64   "$APPICON/icon_32x32@2x.png"
render "$ICON"       128  "$APPICON/icon_128x128.png"
render "$ICON"       256  "$APPICON/icon_128x128@2x.png"
render "$ICON"       256  "$APPICON/icon_256x256.png"
render "$ICON"       512  "$APPICON/icon_256x256@2x.png"
render "$ICON"       512  "$APPICON/icon_512x512.png"
render "$ICON"       1024 "$APPICON/icon_512x512@2x.png"

mkdir -p "$MENUBAR"
render "$GLYPH" 18 "$MENUBAR/menubar-glyph.png"
render "$GLYPH" 36 "$MENUBAR/menubar-glyph@2x.png"

for name in "${EXPLORATIONS[@]}"; do
  for px in 128 32 16; do
    render "$ICON_DIR/explorations/$name.svg" "$px" "$WORK/$name-$px.png"
  done
done

STYLE='
  * { box-sizing: border-box; }
  body { margin: 0; font: 13px/1.4 -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif; }
  section { padding: 48px; }
  .light { background: #F5F5F7; color: #1D1D1F; }
  .dark { background: #1C1C1E; color: #F5F5F7; }
  .row { display: flex; flex-wrap: wrap; align-items: flex-end; gap: 40px; }
  .row + .row { margin-top: 48px; }
  h2 { margin: 0 0 16px; font-size: 13px; font-weight: 600; }
  figure { margin: 0; display: flex; flex-direction: column; align-items: center; gap: 8px; }
  figure img { display: block; }
  figcaption { font-size: 11px; opacity: 0.5; font-variant-numeric: tabular-nums; }
  .zoom { image-rendering: pixelated; }
'

exploration_rows() {
  for name in "${EXPLORATIONS[@]}"; do
    cat <<HTML
<h2>$name</h2>
<div class="row">
<figure><img width="320" height="320" src="explorations/$name.svg"><figcaption>1024</figcaption></figure>
<figure><img width="128" height="128" src="$(uri "$WORK/$name-128.png")"><figcaption>128</figcaption></figure>
<figure><img width="32" height="32" src="$(uri "$WORK/$name-32.png")"><figcaption>32</figcaption></figure>
<figure><img width="16" height="16" src="$(uri "$WORK/$name-16.png")"><figcaption>16</figcaption></figure>
<figure><img class="zoom" width="128" height="128" src="$(uri "$WORK/$name-32.png")"><figcaption>32 ×4</figcaption></figure>
<figure><img class="zoom" width="128" height="128" src="$(uri "$WORK/$name-16.png")"><figcaption>16 ×8</figcaption></figure>
</div>
HTML
  done
}

ROWS="$(exploration_rows)"
cat > "$ICON_DIR/explorations.html" <<HTML
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>dictum icon explorations</title>
<style>$STYLE</style>
</head>
<body>
<section class="light">
$ROWS
</section>
<section class="dark">
$ROWS
</section>
</body>
</html>
HTML
echo "$ICON_DIR/explorations.html"

I16=$(uri "$APPICON/icon_16x16.png");     I16_2=$(uri "$APPICON/icon_16x16@2x.png")
I32=$(uri "$APPICON/icon_32x32.png");     I32_2=$(uri "$APPICON/icon_32x32@2x.png")
I128=$(uri "$APPICON/icon_128x128.png");  I128_2=$(uri "$APPICON/icon_128x128@2x.png")
I512=$(uri "$APPICON/icon_512x512.png");  I1024=$(uri "$APPICON/icon_512x512@2x.png")
G18=$(uri "$MENUBAR/menubar-glyph.png");  G36=$(uri "$MENUBAR/menubar-glyph@2x.png")

icons() {
  cat <<HTML
<figure><img width="1024" height="1024" src="$I1024"><figcaption>1024</figcaption></figure>
<figure><img width="512" height="512" srcset="$I512 1x, $I1024 2x"><figcaption>512</figcaption></figure>
<figure><img width="128" height="128" srcset="$I128 1x, $I128_2 2x"><figcaption>128</figcaption></figure>
<figure><img width="32" height="32" srcset="$I32 1x, $I32_2 2x"><figcaption>32</figcaption></figure>
<figure><img width="16" height="16" srcset="$I16 1x, $I16_2 2x"><figcaption>16</figcaption></figure>
HTML
}

menubar() {
  cat <<HTML
<div class="menubar"><span class="apple"></span><b>Finder</b><span>File</span><span>Edit</span><span>View</span><span class="spacer"></span><img class="glyph" width="18" height="18" srcset="$G18 1x, $G36 2x"><span class="wifi"></span><span>Thu 22 Oct 19:40</span></div>
HTML
}

cat > "$ICON_DIR/preview.html" <<HTML
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>dictum icon preview</title>
<style>$STYLE
  .menubar { display: flex; align-items: center; gap: 18px; height: 24px; padding: 0 14px; margin-top: 48px; border-radius: 8px; font-size: 13px; }
  .light .menubar { background: rgba(246, 246, 246, 0.85); box-shadow: 0 0 0 0.5px rgba(0, 0, 0, 0.12); color: #000; }
  .dark .menubar { background: rgba(40, 40, 42, 0.85); box-shadow: 0 0 0 0.5px rgba(255, 255, 255, 0.12); color: #FFF; }
  .dark .menubar .glyph { filter: invert(1); }
  .menubar .spacer { flex: 1; }
  .menubar .apple { width: 12px; height: 14px; border-radius: 6px 6px 5px 5px; background: currentColor; }
  .menubar .wifi { width: 16px; height: 12px; border-radius: 16px 16px 0 0; border: 2px solid currentColor; border-bottom: none; opacity: 0.85; }
  .menubar .glyph { display: block; }
</style>
</head>
<body>
<section class="light">
<div class="row">
$(icons)
</div>
$(menubar)
</section>
<section class="dark">
<div class="row">
$(icons)
</div>
$(menubar)
</section>
</body>
</html>
HTML
echo "$ICON_DIR/preview.html"
