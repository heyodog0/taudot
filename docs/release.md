# Releasing Taudot

A Taudot.app that runs on another Mac: everything it runs is inside the bundle, the engine runs as a launch agent
from the bundle, updates come by Sparkle. Licences: `NOTICE`, `THIRD_PARTY.md` and `tools/release/notices.py`.

## Checklist

Done:

- **Self-contained bundle** (`clients/mac/bundle.sh`). No path into the repo, `~/code` or `/opt/homebrew`:
  `tools/release/audit.sh` fails on any Mach-O that loads a library from outside `/System`, `/usr/lib` and the
  bundle, on any rpath into the build machine, and on scripts naming a build path. It passes (59 Mach-O files).
  - the engine `Contents/MacOS/taudot` (a fresh copy of the cargo build, never the file cargo overwrites);
  - Neovim 0.12.6, the official release build (system libraries only), in `Resources/neovim`;
  - `txp-render`, `texpresso-xetex` and `taudot-pdfinfo`, with their Homebrew dylibs copied into
    `Contents/Frameworks` and relinked (`tools/release/vendor.py`, `@loader_path`);
  - BibTeX and the live pdfTeX per TeX Live year (already static; system libraries only);
  - **no Tectonic**: TeXpresso's file provider calls `tectonic`, so the bundle carries a 70-line stand-in
    (`tools/release/tectonic`, `Resources/bin`) that answers its three commands from Tectonic's TeX bundle over
    HTTPS with the system's curl, plus a parallel prefetch of what a first XeLaTeX run reads
    (`tectonic-warm.txt`): first PDF on a clean account 8 s instead of 48 s.
- **Lookups prefer the bundle** (`TaudotShared/BundledTools.swift`): engine (`HomeEngine`), Neovim (`findNvim`),
  `texpresso-xetex` and the tectonic stand-in (`TxpPaths`). Outside a bundle, the developer's places as before.
- **The engine as a launch agent from the bundle.** At every launch the app runs `taudot service ensure`
  (`crates/engine/src/service.rs`): installs `app.taudot.engine` pointing at the bundle's binary, repoints it when
  the app moved or the agent came from elsewhere (the repo-path agent on the dev Mac), restarts the engine when the
  binary is newer than the running engine (an update replaces the whole bundle, so the file is new: no
  code-signature kill). Skipped when the app runs from the disk image or translocated. The default label is used
  only for the real user's `~/.taudot`; a `HOME` pointed elsewhere gets its own label (tests can't replace the
  user's agent).
- **First run on a clean account** (`tools/release/clean-run.sh`): `sandbox-exec` denies `/opt/homebrew`,
  `/usr/local` and the whole real home folder; `HOME` empty, `PATH=/usr/bin:/bin`. Every program starts and loads
  only system and bundle libraries; a local pdfLaTeX project, a local XeLaTeX project and a CE project (created and
  cloned by the bundle's engine) all typeset.
- **Licences in the app**: App menu ▸ Acknowledgements and a link in About open `Resources/Acknowledgements.txt`
  (`tools/release/notices.py`): the GPL programs and where their source is, TeXpresso and the licences inside it,
  Neovim, Sparkle, each vendored library's licence files from its Homebrew keg, the engine's 194 Rust crates
  (identical texts printed once), `THIRD_PARTY.md`, the FreeType credit. `COPYING-GPL-2` beside it.
- **GPL source**: `tools/release/gpl-source.sh` → `taudot-gpl-source-VERSION.tar.gz` (clients/pdftex at the release
  commit, which names each TeX Live source release by URL and SHA-512).
- **DMG and updates**: `tools/release/make.sh VERSION` (below). Sparkle 2.10.1 (MIT), loaded at run time
  (`TaudotApp/Updater.swift`; no Swift package dependency), EdDSA-signed appcast. App menu ▸ Check for Updates….
  Tested: 0.1.0 → 0.1.1 from a localhost appcast (`tools/release/update-test.sh`), installed in 6 s, signature
  valid.
- Bundle ID `app.taudot.Taudot`. Unsigned (ad-hoc) for now; Developer ID and notarization slot in (below).

Left:

1. ~~MuPDF and jbig2dec (AGPL) in `txp-render`~~: **gone** (nomupdf, merged 99e55e5). `txp-render` loads only
   system libraries (FreeType, libpng and brotli are linked in statically; their licences are in the notices).
   `make.sh` passes without `ALLOW_AGPL`; the app is 40 Mach-O files, the DMG 60 MB. The bundle ships
   `clients/render/txp-render` only, never `clients/preview/texpresso/txp-headless` (it still links MuPDF).
2. **HarfBuzz from Homebrew links GLib and gettext's libintl (both LGPL-2.1+)** into `texpresso-xetex`. Dynamic and
   replaceable, so allowed with their licence texts (in the notices) and a source offer, but simpler to build
   HarfBuzz without GLib, or link it statically from a HarfBuzz built `-Dglib=disabled`. Also: link Apple's
   `libicucore` instead of Homebrew's ICU (drops the 32 MB `libicudata`), and drop fontconfig (unused on macOS: no
   `Fc` symbol is called). Not cheap with Homebrew alone: it has no static HarfBuzz, graphite2 or ICU, and Apple
   ships no ICU headers, so each means building that library from source in TeXpresso's build (`clients/render`).
3. **The TeX bundle for XeLaTeX comes from Tectonic's relay** (`relay.fullyjustified.net`, TeX Live 2022). The
   stand-in takes any URL (`TAUDOT_TEX_BUNDLE_URL`): mirror the tar and its index on `texlive.taudot.app` when we
   want it under our control.
4. **Hosting** the DMGs, the appcast and the GPL tarball (R2 / `taudot.app/updates/`): needs the user's OK.
   Nothing has been uploaded.
5. **The Sparkle signing key** doesn't exist yet: make it once (below) and back it up (losing it means users can't
   update without downloading by hand).
6. **A real second Mac**: Gatekeeper on a downloaded (quarantined) DMG, first-launch prompts, the agent
   on a fresh account. The clean-account run covers files and libraries, not Gatekeeper.
7. **Developer ID** (when there's a membership): sign with it and notarize (`SIGN_IDENTITY`, `NOTARY_PROFILE`). The
   hardened runtime needs `tools/release/entitlements.plist` (LuaJIT in Neovim: JIT). Check the live pdfTeX's and
   TeXpresso's fork snapshots still work under the hardened runtime.
8. arm64 only (Neovim's build, our Swift and C builds). Intel Macs would need universal builds of each.
9. Rex themes are read from an installed Rex, never shipped. Trademark search for "Taudot".

## How to cut a release

Once per Mac that cuts releases:

```sh
# the EdDSA key for updates, kept in the login Keychain (back it up: generate_keys -x FILE exports it)
~/Library/Caches/taudot-release/downloads/Sparkle-2.10.1/bin/generate_keys --account app.taudot.Taudot
# with a Developer ID later: a notarytool profile (the password stays in the Keychain)
xcrun notarytool store-credentials taudot-notary --apple-id … --team-id …
```

(The Sparkle tools are downloaded by the first `clients/mac/bundle.sh` or `make.sh` run.) The build machine needs
what `bundle.sh` builds from: Xcode's Swift, cargo, a built TeXpresso checkout (`clients/render/texpresso/README.md`),
the live pdfTeX per year (`clients/pdftex/README.md`), and Homebrew's libraries for the TeXpresso builds.

Each release:

1. Commit everything; tag nothing yet.
2. `tools/release/make.sh 0.2` (versions only grow: Sparkle compares them). With a Developer ID:
   `SIGN_IDENTITY="Developer ID Application: …" NOTARY_PROFILE=taudot-notary tools/release/make.sh 0.2`.
3. Check it: `tools/release/clean-run.sh clients/mac/build.noindex/release/0.2/Taudot.app /private/tmp/tdc` (a short
   path: the engine's socket path must fit in 104 bytes) and, before the first public release, open the DMG on
   another Mac.
4. Upload, with the user's OK: from `clients/mac/build.noindex/release/`, `0.2/Taudot-0.2.dmg`,
   `0.2/taudot-gpl-source-0.2.tar.gz` and `updates/appcast.xml` (plus the DMG it points to) to the feed's host
   (`TAUDOT_FEED_URL`, default `https://taudot.app/updates/appcast.xml`; `TAUDOT_DOWNLOAD_PREFIX` for the DMGs).
5. Tag the commit `v0.2`.

Testers on an ad-hoc build: open the DMG, drag Taudot to Applications, open it; macOS refuses the first time, then
System Settings ▸ Privacy & Security ▸ Open Anyway (on macOS 14, right-click ▸ Open).

## Scripts (`tools/release/`)

| script | what |
|---|---|
| `make.sh VERSION` | the release: bundle, audit, DMG, appcast, GPL source |
| `../../clients/mac/bundle.sh [OUT]` | the self-contained app (dev builds too); `TAUDOT_VERSION`, `TAUDOT_FEED_URL`, `TAUDOT_ED_PUBLIC_KEY`, `SIGN_IDENTITY` |
| `pins.sh` | Neovim and Sparkle downloads, pinned by version and SHA-256 |
| `vendor.py APP` | copies non-system dylibs into `Contents/Frameworks` and relinks; collects their licence files |
| `notices.py` | `Acknowledgements.txt` |
| `sign.sh APP [IDENTITY]` | signs inside out (ad-hoc by default) |
| `audit.sh APP` | fails on anything that leaves the bundle, and on AGPL libraries |
| `tectonic`, `tectonic-warm.txt` | the stand-in for Tectonic, and what it prefetches |
| `gpl-source.sh VERSION OUT` | the GPL source tarball |
| `notarize.sh DMG PROFILE` | notarize and staple (Developer ID only) |
| `clean-run.sh APP [WORK]` | the clean-account run |
| `agent-test.sh APP [WORK]` | the launch agent: install, repoint (repo build, moved app), restart after an update |
| `update-test.sh [WORK]` | N → N+1 through Sparkle, from a localhost appcast with a throwaway key |
| `edkey.py` | throwaway EdDSA keys for the update test (releases use the Keychain) |
