#!/usr/bin/env bash
# Renders the README and docs visuals from these HTML pages: each page in a light and a dark
# version, at 2x, into assets/. Needs Google Chrome (or set CHROME). Run from anywhere.
set -euo pipefail
cd "$(dirname "$0")"
chrome=${CHROME:-"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"}
command -v "$chrome" >/dev/null || [ -x "$chrome" ] || chrome=$(command -v google-chrome || command -v chromium)
out=..
shot() {  # page width height name [query]
  for theme in light dark; do
    "$chrome" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=2 \
      --window-size="$2,$3" --virtual-time-budget=2000 \
      --screenshot="$out/$4-$theme.png" "file://$PWD/$1?theme=$theme${5:+&$5}" >/dev/null 2>&1
  done
  echo "$4"
}
shot banner.html 1280 480 banner
shot instinct.html 1280 640 instinct
shot architecture.html 1280 620 architecture
shot install.html 1280 640 install
shot endcard.html 1280 360 endcard
# GitHub's social preview (repo Settings → Social preview): one image, dark.
"$chrome" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 --window-size=1280,640 \
  --virtual-time-budget=2000 --screenshot="$out/social-preview.png" "file://$PWD/social.html?theme=dark" >/dev/null 2>&1
echo social-preview
