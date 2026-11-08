# Recording the site's clips

All on the local Overleaf CE, with a made-up paper (`paper/main.tex`). Never a real project.

1. `project.sh` makes a fresh CE project with the paper, owned by Alice (user1), shared with Bob (user2).
2. `env -u REX_SERVER -u REX_SESSION -u REX_BLOCK TAUDOT_EDITOR_MODE=native TAUDOT_CLAUDE="claude --permission-mode acceptEdits" session.sh PROJECT_ID /tmp/th` starts the real engine as Alice (its own home, never `~/.taudot`) and the debug
   app in Neovim mode, on screen but behind every window (`TAUDOT_ONSCREEN=1`). Use a short folder: socket paths
   overflow otherwise. Neovim listens on `/tmp/td/nvim.sock`; load `demo.lua` into it (`demo.type`, `demo.at`).
3. A second engine as Bob (`taudot serve --user user2 --home /tmp/tdb/home`) adds his comments (`comment.add`).
4. `record.swift` records the app's window (ScreenCaptureKit, desktop-independent: windows over it don't show).
   - Clip 1: `demo.type` into Neovim while recording.
   - Clip 2: `bob.mjs` types as Bob in Overleaf's own editor (the harness's `serve.ts`, headless).
   - Clip 3: `clip3.sh`: Bob comments, then Alice replies with ⌥⌘↩ and real keys. This one needs the app in front
     for about 12 s (`raise.py`), so ask before running it; `keys.swift` posts keys to the app's process only, so
     nothing lands in another app if the raise fails.
5. `tools/clip.sh RAW.mov ID START LENGTH 2400:1350:0:56` (the crop drops the title bar), then `ready: true` in
   `src/pages.js`.

The app's status bar polling pauses while its window is covered: call `package.loaded['taudot.app'].pause(false)`
before recording. Afterwards, delete the `/tmp/td` layout keys the debug app saved (`defaults read taudot-app`).

Since the native-editor retakes: `bobtype.mjs` types as Bob through his engine, one character per edit (live, not
batched); `act.swift` sends keys, text and clicks to the app's pid (`k:CODE:MODS`, `t:TEXT`, `C:X,Y`, `D:X,Y`).
Turn the user's `taudot.vimKeys` off for the takes and back on after. Camera moves for each clip: `shots/*.json`.

For a steady sidebar in recordings: raise the app before recording, run `backdrop WINDOW X Y W H` (Taudot's window in
screen points) for the take, keep the app in front until the recording stops, then kill the backdrop.

Pointer in post: run `act` with `ACTLOG=FILE` during an uncursored take; `record` prints `recording EPOCH`. Put
`"pointer": {"log": FILE, "t0": EPOCH, "origin": [X, Y]}` (window origin in screen points) in the shot, and
`camera.py` draws a large pointer with click rings.
