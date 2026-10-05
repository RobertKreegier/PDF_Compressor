#!/usr/bin/env bash

strIconName="FPDF_Clamped"

mkdir -p "$strIconName".iconset
sips -z 16 16     "$strIconName".png --out "$strIconName".iconset/icon_16x16.png
sips -z 32 32     "$strIconName".png --out "$strIconName".iconset/icon_16x16@2x.png
sips -z 32 32     "$strIconName".png --out "$strIconName".iconset/icon_32x32.png
sips -z 64 64     "$strIconName".png --out "$strIconName".iconset/icon_32x32@2x.png
sips -z 128 128   "$strIconName".png --out "$strIconName".iconset/icon_128x128.png
sips -z 256 256   "$strIconName".png --out "$strIconName".iconset/icon_128x128@2x.png
sips -z 256 256   "$strIconName".png --out "$strIconName".iconset/icon_256x256.png
sips -z 512 512   "$strIconName".png --out "$strIconName".iconset/icon_256x256@2x.png
sips -z 512 512   "$strIconName".png --out "$strIconName".iconset/icon_512x512.png
sips -z 1024 1024 "$strIconName".png --out "$strIconName".iconset/icon_512x512@2x.png

iconutil -c icns "$strIconName".iconset