# Sourced by clients/mac/bundle.sh and tools/release/make.sh: the third-party downloads the app is built with, pinned
# by version and SHA-256, and `fetch` (cached in $dl). Bump a version: change it and its SHA-256 together.
dl=${TAUDOT_DOWNLOADS:-$HOME/Library/Caches/taudot-release/downloads}
mkdir -p "$dl"
NVIM_VERSION=0.12.6
NVIM_URL=https://github.com/neovim/neovim/releases/download/v$NVIM_VERSION/nvim-macos-arm64.tar.gz
NVIM_SHA=1dbd148222b051ba6c307c4d17a318ed083df018a4f6a5a0ce46955ffc9ab87b
NVIM_LICENSE_URL=https://raw.githubusercontent.com/neovim/neovim/v$NVIM_VERSION/LICENSE.txt
NVIM_LICENSE_SHA=de23202ef9a51f5e654034190539739a4abece5505f2ce75e780791106707011
SPARKLE_VERSION=2.10.1
SPARKLE_URL=https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz
SPARKLE_SHA=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27
fetch() {  # fetch NAME URL SHA256 → prints the cached file
  f="$dl/$1"
  if [ ! -f "$f" ] || [ "$(shasum -a 256 "$f" | cut -d' ' -f1)" != "$3" ]; then
    curl -fsSL -o "$f.part" "$2" && mv -f "$f.part" "$f"
  fi
  [ "$(shasum -a 256 "$f" | cut -d' ' -f1)" = "$3" ] || { echo "checksum mismatch for $2" >&2; exit 1; }
  echo "$f"
}
# sparkle → prints the unpacked Sparkle folder (Sparkle.framework, bin/)
sparkle() {
  t=$(fetch "Sparkle-$SPARKLE_VERSION.tar.xz" "$SPARKLE_URL" "$SPARKLE_SHA")
  d="$dl/Sparkle-$SPARKLE_VERSION"
  [ -d "$d/Sparkle.framework" ] || { mkdir -p "$d" && tar -xJf "$t" -C "$d"; }
  echo "$d"
}
