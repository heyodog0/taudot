# tau-attach

A program in a pty that outlives the terminal showing it, shared by several terminals at once (the idea of dtach).
The Mac app's Claude pane runs `claude` this way (`clients/mac/Sources/TaudotApp/ClaudeSession.swift`): the
conversation survives Taudot quitting, and with Rex it runs in a block of the project's Rex session, so it shows in
Rex too.

```sh
sh build.sh                                  # cc, libc only
tau-attach new [-d] SOCKET -- CMD [ARG...]   # CMD in a pty behind SOCKET; attach this terminal (-d: don't)
tau-attach attach SOCKET                     # attach: output, input, size; EOF on stdin detaches
tau-attach status SOCKET                     # CMD's pid; exit 1 when nothing runs there
```

- Several clients at once. The one that typed last sets the size; one that has only attached sets it when nobody
  else has.
- A client that attaches gets the last 256 KiB of output, then the program is asked to redraw (SIGWINCH).
- When CMD exits, every client exits with its status and the socket is removed. `new` on a live socket exits 3.
- Wire format (both ways): a type byte, a 4-byte big-endian length, the payload. Server → client: `H` pid, `O`
  output, `X` exit status. Client → server: `I` input, `W` rows and columns (two u16).

Tests: `clients/mac/Tests/TaudotTests/AttachTests.swift`; the app's use of it: `clients/mac/Tests/shell_claude.sh`.
When Rex can attach to a block itself (`rex attach` / `rex block stream`), the pane switches to that.
