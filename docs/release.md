# Releasing Taudot

A Taudot.app that runs on another Mac: everything it runs is inside the bundle, the engine runs as a launch agent
from the bundle, updates come by Sparkle. Licences: `NOTICE`, `THIRD_PARTY.md` and `tools/release/notices.py`.

## What the bundle does

- **Self-contained** (`clients/mac/bundle.sh`). `tools/release/audit.sh` fails on any Mach-O that loads a library
  from outside `/System`, `/usr/lib` and the bundle, on any rpath into the build machine, on scripts naming a build
  path, and on AGPL libraries. The app is 40 Mach-O files, the DMG 60 MB. It holds:
  - the engine `Contents/MacOS/taudot` (a fresh copy of the cargo build, never the file cargo overwrites);
  - Neovim 0.12.6, the official release build, in `Resources/neovim`;
  - `txp-render`, `texpresso-xetex` and `taudot-pdfinfo`, with Homebrew dylibs copied into `Contents/Frameworks`
    and relinked (`tools/release/vendor.py`, `@loader_path`). `txp-render` loads only system libraries (FreeType,
    libpng and brotli linked statically). Never `clients/preview/texpresso/txp-headless` (it links MuPDF, AGPL);
  - BibTeX and the live pdfTeX per TeX Live year (static; system libraries only);
  - `Resources/universal`: `tau-live`, `libtau.dylib`, stock pdfTeX, XeTeX, LuaTeX and their formats
    (`docs/universal.md`), sharing the live pdfTeX's 2026 tree;
  - **no Tectonic**: a 70-line stand-in (`tools/release/tectonic`) answers TeXpresso's three `tectonic` commands from
    Tectonic's TeX bundle with the system's curl, prefetching a first XeLaTeX run's files: first PDF in 8 s, not 48 s.
- **Lookups prefer the bundle** (`TaudotShared/BundledTools.swift`): engine (`HomeEngine`), Neovim (`findNvim`),
  `texpresso-xetex` and the tectonic stand-in (`TxpPaths`). Outside a bundle, the developer's places.
- **Launch agent.** At every launch the app runs `taudot service ensure` (`crates/engine/src/service.rs`): installs
  or repoints `app.taudot.engine` at the bundle's binary and restarts the engine when the binary is newer. Skipped
  from the disk image or when translocated. Another `HOME` gets its own label.
- **Clean-account run** (`clean-run.sh`): `sandbox-exec` denies `/opt/homebrew`, `/usr/local` and the real home,
  `PATH=/usr/bin:/bin`. A local pdfLaTeX, a local XeLaTeX and a CE project all typeset.
- **Licences**: App menu ▸ Acknowledgements and About open `Resources/Acknowledgements.txt` (`notices.py`): the GPL
  programs and their source, TeXpresso, Neovim, Sparkle, vendored libraries, the engine's 194 Rust crates,
  `THIRD_PARTY.md`, the FreeType credit; `COPYING-GPL-2` beside it.
- **GPL source**: `tools/release/gpl-source.sh` makes `taudot-gpl-source-VERSION.tar.gz` (clients/pdftex at the
  release commit, which names each TeX Live source release by URL and SHA-512).
- **Updates**: Sparkle 2.10.1 (MIT), loaded at run time (`TaudotApp/Updater.swift`), EdDSA-signed appcast.
  `update-test.sh`: 0.1.0 → 0.1.1 from a localhost appcast in 6 s.
- Bundle ID `app.taudot.Taudot`. Ad-hoc signed for now.

## Open items

1. **Homebrew's HarfBuzz links GLib and libintl (LGPL-2.1+)** into `texpresso-xetex`: allowed (dynamic, licences in
   the notices, source offer), but simpler to link a HarfBuzz built `-Dglib=disabled` statically. Also: Apple's
   `libicucore` for Homebrew's ICU (drops the 32 MB `libicudata`), and no fontconfig (unused). Each means building the
   library in `clients/render`'s TeXpresso build.
2. **XeLaTeX's TeX bundle comes from Tectonic's relay** (`relay.fullyjustified.net`, TeX Live 2022);
   `TAUDOT_TEX_BUNDLE_URL` can point at a mirror on `texlive.taudot.app`.
3. **Hosting** the DMGs, appcast and GPL tarball (`taudot.app/updates/`): needs the owner's OK. Nothing is uploaded.
4. **The Sparkle signing key** doesn't exist yet: make it once (below) and back it up.
5. **A real second Mac**: Gatekeeper on a quarantined DMG, first-launch prompts, the agent on a fresh account.
6. **Developer ID**: sign and notarize (`SIGN_IDENTITY`, `NOTARY_PROFILE`), with `tools/release/entitlements.plist`
   (LuaJIT in Neovim); check the fork snapshots under the hardened runtime.
7. arm64 only.
8. Rex themes are read from an installed Rex, never shipped. Trademark search for "Taudot".

## Cutting a release

Once per Mac:

```sh
# the EdDSA key for updates, in the login Keychain (back it up: generate_keys -x FILE exports it)
~/Library/Caches/taudot-release/downloads/Sparkle-2.10.1/bin/generate_keys --account app.taudot.Taudot
# with a Developer ID: a notarytool profile
xcrun notarytool store-credentials taudot-notary --apple-id … --team-id …
```

The first `bundle.sh` or `make.sh` run downloads the Sparkle tools. The build machine needs Xcode's Swift, cargo, a
built TeXpresso (`clients/render/texpresso/README.md`), the live pdfTeX per year (`clients/pdftex/DESIGN.md`) and
Homebrew's libraries.

Each release:

1. Commit everything; tag nothing yet.
2. `tools/release/make.sh 0.2` (versions only grow: Sparkle compares them). With a Developer ID:
   `SIGN_IDENTITY="Developer ID Application: …" NOTARY_PROFILE=taudot-notary tools/release/make.sh 0.2`.
3. `tools/release/clean-run.sh clients/mac/build.noindex/release/0.2/Taudot.app /private/tmp/tdc` (short: the
   socket path must fit in 104 bytes).
4. Upload, with the owner's OK, from `clients/mac/build.noindex/release/`: `0.2/Taudot-0.2.dmg`,
   `0.2/taudot-gpl-source-0.2.tar.gz` and `updates/appcast.xml` (and its DMG) to the feed's host (`TAUDOT_FEED_URL`,
   default `https://taudot.app/updates/appcast.xml`; `TAUDOT_DOWNLOAD_PREFIX` for the DMGs).
5. Tag the commit `v0.2`.

Testers on an ad-hoc build: drag Taudot to Applications and open it; after the first refusal, System Settings ▸
Privacy & Security ▸ Open Anyway (macOS 14: right-click ▸ Open).

## Scripts (`tools/release/`)

| script | what |
|---|---|
| `make.sh VERSION` | the release: bundle, audit, DMG, appcast, GPL source |
| `../../clients/mac/bundle.sh [OUT]` | the self-contained app (dev builds too); `TAUDOT_VERSION`, `TAUDOT_FEED_URL`, `TAUDOT_ED_PUBLIC_KEY`, `SIGN_IDENTITY` |
| `pins.sh` | Neovim and Sparkle downloads, pinned by version and SHA-256 |
| `vendor.py APP` | copies non-system dylibs into `Contents/Frameworks`, relinks, collects their licence files |
| `notices.py` | `Acknowledgements.txt` |
| `sign.sh APP [IDENTITY]` | signs inside out (ad-hoc by default) |
| `audit.sh APP` | fails on anything that leaves the bundle, and on AGPL libraries |
| `tectonic`, `tectonic-warm.txt` | the Tectonic stand-in, and what it prefetches |
| `gpl-source.sh VERSION OUT` | the GPL source tarball |
| `notarize.sh DMG PROFILE` | notarize and staple (Developer ID only) |
| `clean-run.sh APP [WORK]` | the clean-account run |
| `agent-test.sh APP [WORK]` | the launch agent: install, repoint (repo build, moved app), restart after an update |
| `update-test.sh [WORK]` | N → N+1 through Sparkle, from a localhost appcast with a throwaway key |
| `edkey.py` | throwaway EdDSA keys for the update test (releases use the Keychain) |
