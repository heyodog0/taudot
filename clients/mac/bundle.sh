#!/bin/sh
# Build Taudot.app, self-contained: ./bundle.sh [OUTDIR]   (default: clients/mac/build.noindex; .noindex keeps dev
# builds out of Spotlight). Everything the app runs is inside it (docs/release.md has the layout and the checks):
#   Contents/MacOS/taudot-app, taudot (the engine; the app points its launch agent here)
#   Contents/Resources/neovim/           Neovim's official release build (system libraries only)
#   Contents/Resources/nvim/             the Neovim plugin (clients/nvim)
#   Contents/Resources/txp-render        TeXpresso's driver (the live XeLaTeX preview)
#   Contents/Resources/tau-attach        the Claude pane's shared terminal (clients/attach)
#   Contents/Resources/texpresso/        texpresso-xetex and taudot-pdfinfo
#   Contents/Resources/bin/tectonic      the stand-in TeXpresso's file provider calls (tools/release/tectonic)
#   Contents/Resources/bibtex/, pdftex/  TeX Live's BibTeX; the live pdfTeX per TeX Live year (GPL, separate programs)
#   Contents/Resources/universal/        tau-live, libtau, tau-tdl; stock pdfTeX, XeTeX, LuaTeX, tau-pdfmx (GPL) and formats
#   Contents/Frameworks/                 the vendored dylibs (tools/release/vendor.py) and Sparkle.framework
#   Contents/Resources/Acknowledgements.txt, COPYING-GPL-2
# Environment: TAUDOT_VERSION (CFBundleShortVersionString and CFBundleVersion; default 0.1 and the git description),
# TAUDOT_FEED_URL and TAUDOT_ED_PUBLIC_KEY (Sparkle's feed and EdDSA key; no updater without them),
# SIGN_IDENTITY (default "-", ad-hoc), TEXPRESSO_DIR, PDFTEX_REF, BIBTEX_BIN, TAUDOT_DOWNLOADS.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
rel="$repo/tools/release"
out=${1:-"$here/build.noindex"}
app="$out/Taudot.app"
. "$rel/pins.sh"
note() { echo "note: $*" >&2; }

cd "$here"
swift build -c release --product taudot-app
bin=$(swift build -c release --show-bin-path)/taudot-app
(cd "$repo" && cargo build --release -q -p taudot-engine)

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/nvim" "$app/Contents/Frameworks"
cp "$bin" "$app/Contents/MacOS/taudot-app"
# A fresh copy, never the cargo output itself (macOS kills a process whose signed binary is overwritten in place).
cp "$repo/target/release/taudot" "$app/Contents/MacOS/taudot"
for d in lua plugin doc; do
  [ -d "$here/../nvim/$d" ] && cp -R "$here/../nvim/$d" "$app/Contents/Resources/nvim/"
done

# Neovim
t=$(fetch "nvim-$NVIM_VERSION-macos-arm64.tar.gz" "$NVIM_URL" "$NVIM_SHA")
mkdir -p "$app/Contents/Resources/neovim"
tar -xzf "$t" -C "$app/Contents/Resources/neovim" --strip-components 1
nvim_licence=$(fetch "neovim-$NVIM_VERSION-LICENSE.txt" "$NVIM_LICENSE_URL" "$NVIM_LICENSE_SHA")

# TeXpresso: the driver (txp-render: our renderer, no MuPDF; FreeType, libpng and brotli linked statically) and the
# engine with its PDF helper. Never clients/preview/texpresso/txp-headless (it links MuPDF, AGPL).
V="$repo/vendor/texpresso"
[ -d "$V" ] && T="${TEXPRESSO_DIR:-$V}" || T="${TEXPRESSO_DIR:-$HOME/code/lab/taudot-ref/texpresso}"
rnd="$here/../render/txp-render"
if [ ! -x "$rnd" ] || [ -n "$(find "$here/../render" \( -name '*.c' -o -name '*.h' -o -name '*.swift' -o -name build.sh \) -not -path '*/.build/*' -not -path '*/harness/*' -newer "$rnd" | head -1)" ]; then
  TEXPRESSO_DIR="$T" sh "$here/../render/build.sh" >&2 || note "building txp-render failed"
fi
[ -x "$rnd" ] && cp "$rnd" "$app/Contents/Resources/" || note "no txp-render: XeLaTeX projects have no preview"
# tau-attach: the Claude pane's claude runs behind it (in the project's Rex session when Rex is there), so it outlives
# the app and Rex can show it too (ClaudeSession.swift). libc only.
att="$here/../attach/tau-attach"
if [ ! -x "$att" ] || [ "$here/../attach/tau-attach.c" -nt "$att" ]; then sh "$here/../attach/build.sh" >&2 || note "building tau-attach failed"; fi
[ -x "$att" ] && cp "$att" "$app/Contents/Resources/" || note "no tau-attach: the Claude pane runs claude in a plain terminal"
mkdir -p "$app/Contents/Resources/texpresso" "$app/Contents/Resources/bin"
for f in texpresso-xetex taudot-pdfinfo; do
  if [ -x "$T/build/$f" ]; then cp "$T/build/$f" "$app/Contents/Resources/texpresso/"; else note "no $T/build/$f (make -C $T all)"; fi
done
cp "$rel/tectonic" "$app/Contents/Resources/bin/tectonic"
cp "$rel/tectonic-warm.txt" "$app/Contents/Resources/"

# TeX Live's BibTeX 0.99d (static; Overleaf's), with BibTeX's texmf.cnf settings: the driver's BibTeX for project styles.
# Built from TeX Live's source (clients/pdftex builds it; or set BIBTEX_BIN).
bibtex=${BIBTEX_BIN:-$HOME/code/lab/taudot-ref/pdftex-build-2025/stock/texk/web2c/bibtex}
if [ -x "$bibtex" ]; then
  mkdir -p "$app/Contents/Resources/bibtex"
  cp "$bibtex" "$here/../render/bibtex/texmf.cnf" "$app/Contents/Resources/bibtex/"
else note "no TeX Live bibtex at $bibtex; BibTeX falls back to Tectonic's (loses spaces in @STRING values)"; fi
# The live pdfTeX (clients/pdftex, GPL, separate executables), per TeX Live year: the driver, the engine (run as
# pdflatex), BibTeX, the format, and the tree's skeleton (ls-R files, TeX Live's texmf.cnf). The app makes the
# writable tree under ~/Library/Caches/taudot/texlive-YEAR at first use; files are fetched from the TeX Live store.
# Built by clients/pdftex/build.sh (SERIES=YEAR) and texlive/tl.py store YEAR; PDFTEX_REF to look elsewhere.
ref=${PDFTEX_REF:-$HOME/code/lab/taudot-ref}
for year in 2026 2025 2024; do
  b="$ref/pdftex-build-$year" t="$ref/texlive-$year/store-root" d="$app/Contents/Resources/pdftex/$year"
  if [ ! -x "$b/pdftex-live" ] || [ ! -x "$b/live/texk/web2c/pdftex" ] || [ ! -f "$b/fmt-live/pdflatex.fmt" ] || [ ! -f "$t/texmf-dist/ls-R" ]; then
    note "no live pdfTeX for TeX Live $year (clients/pdftex); its pdfLaTeX projects use TeXpresso"; continue
  fi
  mkdir -p "$d/fmt" "$d/tree/texmf-dist/web2c" "$d/tree/texmf-var"
  cp "$b/pdftex-live" "$b/live/texk/web2c/pdftex" "$d/"
  ln -sf pdftex "$d/pdflatex"
  [ -x "$b/stock/texk/web2c/bibtex" ] && cp "$b/stock/texk/web2c/bibtex" "$d/"
  cp "$b/fmt-live/pdflatex.fmt" "$d/fmt/"
  cp "$t/texmf-dist/ls-R" "$d/tree/texmf-dist/"
  [ -f "$t/texmf-var/ls-R" ] && cp "$t/texmf-var/ls-R" "$d/tree/texmf-var/"
  cp "$t/texmf-dist/web2c/texmf.cnf" "$d/tree/texmf-dist/web2c/"
  [ -f "$t/texmf-dist/web2c/cp227.tcx" ] && cp "$t/texmf-dist/web2c/cp227.tcx" "$d/tree/texmf-dist/web2c/"
done
# Universal (clients/universal, MIT): tau-live, libtau.dylib (beside it: tau-live loads it into the engines) and
# tau-tdl, with TeX Live 2026's stock pdfTeX, XeTeX, LuaHBTeX and BibTeX, and tau-pdfmx (xdvipdfmx kept resident: the stock
# dvipdfm-x objects; tau-live converts XeTeX's pages with it) (GPL, separate programs, the TeX Live code not
# modified) and the formats those engines built. The engines' zlib dylib (TeX Live's own) is vendored below with the
# rest. They share the live pdfTeX's 2026 tree. Built by clients/universal/{build-engines,build,build-formats}.sh.
ub="$ref/universal/bin" uf="$ref/universal/fmt-2026" d="$app/Contents/Resources/universal"
if [ -x "$ub/tau-live" ] && [ -f "$ub/libtau.dylib" ] && [ -f "$uf/xelatex.fmt" ] && [ -d "$app/Contents/Resources/pdftex/2026/tree" ]; then
  mkdir -p "$d/bin" "$d/fmt"
  for f in tau-live libtau.dylib tau-tdl tau-pdfmx pdftex xetex luahbtex bibtex; do
    if [ -e "$ub/$f" ]; then cp -L "$ub/$f" "$d/bin/$f"; else note "universal: no $f in $ub"; fi
  done
  ln -sf pdftex "$d/bin/pdflatex"; ln -sf xetex "$d/bin/xelatex"; ln -sf luahbtex "$d/bin/lualatex"
  ln -sf tau-pdfmx "$d/bin/xdvipdfmx"  # (tau-pdfmx names itself xdvipdfmx beside it; kpathsea needs the name to exist)
  install_name_tool -id @loader_path/libtau.dylib "$d/bin/libtau.dylib" 2>/dev/null
  for f in pdflatex xelatex lualatex; do
    if [ -f "$uf/$f.fmt" ]; then cp "$uf/$f.fmt" "$d/fmt/"; else note "universal: no $f.fmt; those projects fall back"; fi
  done
else note "no universal build in $ref/universal (or no 2026 tree); XeLaTeX/LuaLaTeX projects use TeXpresso"; fi
# The icon: Assets.car from the Icon Composer document (macOS 26 draws its glass, dark, tinted and clear looks),
# and actool's AppIcon.icns for older macOS. Both from docs/design/logo/build_icon.py.
cp "$repo/docs/design/logo/final/car/Assets.car" "$repo/docs/design/logo/final/car/AppIcon.icns" "$app/Contents/Resources/"

# Sparkle (MIT): loaded at run time by Updater.swift; only useful with a feed and a key.
sp=$(sparkle)
ditto "$sp/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"

version=${TAUDOT_VERSION:-}
short=${version:-0.1}
build=${version:-$(git -C "$here" describe --always --dirty 2>/dev/null || echo dev)}
sparkle_keys=""
if [ -n "${TAUDOT_FEED_URL:-}" ] && [ -n "${TAUDOT_ED_PUBLIC_KEY:-}" ]; then
  sparkle_keys="  <key>SUFeedURL</key><string>$TAUDOT_FEED_URL</string>
  <key>SUPublicEDKey</key><string>$TAUDOT_ED_PUBLIC_KEY</string>
  <key>SUEnableAutomaticChecks</key><true/>"
fi
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Taudot</string>
  <key>CFBundleDisplayName</key><string>Taudot</string>
  <key>CFBundleIdentifier</key><string>app.taudot.Taudot</string>
  <key>CFBundleExecutable</key><string>taudot-app</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$short</string>
  <key>CFBundleVersion</key><string>$build</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSArchitecturePriority</key><array><string>arm64</string></array>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>NSHumanReadableCopyright</key><string>© 2026 Taudot</string>
$sparkle_keys
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Folder</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSItemContentTypes</key><array><string>public.folder</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

# Vendor the Homebrew dylibs, write the notices from what was vendored, sign inside out, audit.
lic=$(mktemp -d)
uv run --no-project --quiet python "$rel/vendor.py" "$app" --licences "$lic" > "$out/vendored.txt"
uv run --no-project --quiet python "$rel/notices.py" "$app/Contents/Resources/Acknowledgements.txt" --licences "$lic" \
  --texpresso "$T" --neovim-licence "$nvim_licence" --sparkle-licence "$sp/LICENSE" --version "$short" \
  $([ -d "$app/Contents/Resources/universal" ] && [ -d "$ref/universal/src-2026" ] && printf -- '--texlive-src %s ' "$ref/universal/src-2026") \
  $(B=$(brew --prefix 2>/dev/null) && for k in freetype libpng brotli; do [ -d "$B/opt/$k" ] && printf -- '--static-keg %s ' "$B/opt/$k"; done) >&2
rm -rf "$lic"
cp "$rel/COPYING-GPL-2" "$app/Contents/Resources/"
sh "$rel/sign.sh" "$app" "${SIGN_IDENTITY:--}" >&2
sh "$rel/audit.sh" "$app" --allow-agpl >&2 || note "the audit failed (above)"
echo "$app"
