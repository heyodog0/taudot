#!/bin/sh
# Builds the pdfrender daemon next to this script. The preview uses it when it exists, else pdftoppm.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
swiftc -O -o "$here/pdfrender" "$here/pdfrender.swift" -framework CoreGraphics
echo "$here/pdfrender"
