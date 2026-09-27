#!/bin/bash
# Build Superpaint.app — draw over anything.
set -e
cd "$(dirname "$0")"
rm -rf Superpaint.app
mkdir -p Superpaint.app/Contents/MacOS
swiftc -O Sources/*.swift -o Superpaint.app/Contents/MacOS/Superpaint
cp Info.plist Superpaint.app/Contents/Info.plist
echo "built $(pwd)/Superpaint.app"
