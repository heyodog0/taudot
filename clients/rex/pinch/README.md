# taudot-pinch

Trackpad pinch and smart zoom (two-finger double-tap) for the PDF preview in Rex.

A terminal has no way to tell a program about a pinch, and Rex uses pinch to zoom panes. This small macOS helper
watches trackpad gestures with an event tap. A pinch that **starts over a Taudot preview pane** is taken out of the
event stream and sent to that preview over its socket, with its phases (began, changed, ended). Anywhere else the
gesture passes through untouched, so Rex's pinch-to-zoom-pane still works on every other pane.

The preview zooms continuously at the pointer while you pinch, on a snapshot image, and re-renders sharp when the
gesture ends. Two-finger double-tap toggles between fit-width and the last zoom.

## Build and run

```sh
clients/rex/pinch/build.sh            # builds clients/rex/pinch/build.noindex/TaudotPinch.app (ad-hoc signed)
open -g clients/rex/pinch/build.noindex/TaudotPinch.app
```

`taudot-layout.sh` starts it when it is built and not running. It has no window or Dock icon; one instance serves
every preview. Quit it with `pkill -x taudot-pinch`. It logs to `~/.taudot/rex/pinch.log`.

## Permission

An event tap that can swallow events needs **Accessibility**. On first start macOS asks; otherwise:

1. System Settings → Privacy & Security → Accessibility.
2. Click **+**, choose `clients/rex/pinch/build.noindex/TaudotPinch.app`, and turn it on.
3. Nothing to restart: the helper checks every 2 s and turns its tap on (`event tap on` in the log).

The app is ad-hoc signed, so macOS ties the permission to this exact build. **After a rebuild, remove the old entry
(−) and add the app again**, or the switch shows on but does nothing.

## How it finds the pane

The preview turns on mouse motion reporting and, while a helper is connected, sends where the pointer is inside its
pane as it moves (`{"hover": {x, y, pw, ph}}`, device pixels). At that moment the helper reads the pointer's global
position, so the difference is the pane's position on screen. A pinch is taken when Rex is the frontmost app and the
pointer is inside a pane seen in the last two minutes.

Limits: if the layout changes (a pane moved or another tab shown) and the pointer hasn't moved over the preview
since, the old rectangle is used until it does; worst case a pinch over another pane in the same spot goes to the
preview. A display scale other than the screen's backing scale would put the rectangle off.
