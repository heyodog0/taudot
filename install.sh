#!/bin/sh
# Build and install Taudot on this Mac: the sync engine (`taudot`, run at login), TeXpresso's driver, the app
# (~/Applications/Taudot.app, built in clients/mac/build.noindex) and `txs`. Run it again after `git pull` to update.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
bin="${TAUDOT_BIN:-${TEXSYNC_BIN:-$HOME/.local/bin}}"
say() { printf '\n==> %s\n' "$*"; }

xcode-select -p >/dev/null 2>&1 || { echo "Install the Xcode command line tools first: xcode-select --install"; exit 1; }
command -v brew >/dev/null || { echo "Install Homebrew first: https://brew.sh"; exit 1; }

say "Homebrew packages"
need=""
for f in neovim mupdf sdl2 pkgconf tectonic; do brew list --formula "$f" >/dev/null 2>&1 || need="$need $f"; done
command -v cargo >/dev/null || need="$need rust"
[ -z "$need" ] || brew install $need

say "TeXpresso"
T="$here/vendor/texpresso"
# Upstream at the pinned commit plus our patch series (branch `taudot`), cloned if missing. A clone from before the
# series still carries the old sed edit: discard it once.
[ -d "$T/.git" ] && git -C "$T" diff --quiet || { [ -d "$T/.git" ] && git -C "$T" checkout -q .; }
sh "$here/clients/render/texpresso/apply.sh" "$T"
make -C "$T" -j"$(sysctl -n hw.ncpu)" all
TEXPRESSO_DIR="$T" sh "$here/clients/preview/texpresso/build.sh"
TEXPRESSO_DIR="$T" sh "$here/clients/render/build.sh"

say "Sync engine"
(cd "$here" && cargo build -q --release -p taudot-engine)
mkdir -p "$bin"
ln -sf "$here/target/release/taudot" "$bin/taudot"
# The command's name before the rename (2026-11-04), kept for scripts and habits: same binary.
[ -L "$bin/texsync" ] && ln -sf "$here/target/release/taudot" "$bin/texsync"
[ -n "${TAUDOT_NO_SERVICE:-${TEXSYNC_NO_SERVICE:-}}" ] || "$bin/taudot" service install

say "The app"
TEXPRESSO_DIR="$T" "$here/clients/mac/bundle.sh" >/dev/null
# One copy in ~/Applications for Spotlight and the Dock; the build folders are .noindex. txs refreshes it.
apps="${TAUDOT_APP_DIR:-$HOME/Applications}"
mkdir -p "$apps" "$HOME/.taudot"
rm -rf "$apps/Taudot.app" && ditto "$here/clients/mac/build.noindex/Taudot.app" "$apps/Taudot.app"
printf "%s\n" "$here" > "$HOME/.taudot/app-source"
ln -sf "$here/clients/mac/txs" "$bin/txs"

case ":$PATH:" in *":$bin:"*) ;; *) echo "Add $bin to your PATH (e.g. in ~/.zshrc: export PATH=\"\$HOME/.local/bin:\$PATH\")";; esac
say "Done. Next: taudot login, then taudot clone <overleaf project url> <folder>, then txs <folder>"
