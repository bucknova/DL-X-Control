#!/bin/zsh
# Packages the built app into a disk image: ./make_dmg.sh output-name.dmg
set -e
cd "${0:A:h}"
OUT="${1:?Usage: make_dmg.sh output.dmg}"
STAGE="$(mktemp -d)"
cp -R "build/DL-X Control.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$OUT"
hdiutil create -volname "DL-X Control" -srcfolder "$STAGE" -ov -format UDZO "$OUT"
rm -rf "$STAGE"
