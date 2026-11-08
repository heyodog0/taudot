// The preview's side of txp-headless: start it, feed it edits, ask it for tiles, hear about changed pages.

import { dirname, join } from "jsr:@std/path@1";

export interface PagesEvent {
  ev: "pages";
  gen: number;
  n: number;
  typeset: number;
  done: boolean;
  sizes: [number, number][];
  changed: number[];
  edit_us: number;
  step_us: number;
  report_us: number;
}

const here = dirname(new URL(import.meta.url).pathname);
export const TXP_BIN = join(here, "txp-headless");
const XETEX = Deno.env.get("TEXPRESSO_XETEX") ??
  `${Deno.env.get("HOME")}/code/lab/taudot-ref/texpresso/build/texpresso-xetex`;

export class Txp {
  private w: WritableStreamDefaultWriter<Uint8Array>;
  private waiting = new Map<number, (r: Record<string, unknown>) => void>();
  private seq = 0;
  private enc = new TextEncoder();
  private proc: Deno.ChildProcess;
  private lastGoal = -2;

  constructor(mainPath: string, onPages: (e: PagesEvent) => void, stderrPath?: string) {
    const proc = new Deno.Command(TXP_BIN, {
      args: ["-tectonic", mainPath],
      env: { TEXPRESSO_XETEX: XETEX },
      stdin: "piped",
      stdout: "piped",
      stderr: stderrPath ? "piped" : "null",
    }).spawn();
    this.proc = proc;
    this.w = proc.stdin.getWriter();
    if (stderrPath) {
      Deno.open(stderrPath, { write: true, create: true, truncate: true }).then((f) =>
        proc.stderr.pipeTo(f.writable)
      );
    }
    (async () => {
      let buf = "";
      for await (const c of proc.stdout.pipeThrough(new TextDecoderStream())) {
        buf += c;
        let nl;
        while ((nl = buf.indexOf("\n")) >= 0) {
          const line = buf.slice(0, nl);
          buf = buf.slice(nl + 1);
          if (!line.startsWith("{")) continue;
          const m = JSON.parse(line);
          if (m.ev === "pages") onPages(m as PagesEvent);
          else if (m.id !== undefined) {
            this.waiting.get(m.id)?.(m);
            this.waiting.delete(m.id);
          }
        }
      }
    })();
  }

  /** Resolves when the process exits. */
  get exited(): Promise<Deno.CommandStatus> {
    return this.proc.status;
  }

  send(a: unknown[]) {
    return this.w.write(this.enc.encode(JSON.stringify(a) + "\n"));
  }

  /** Whole text of a file (TeXpresso diffs it against what it has and rolls back from the first changed byte). */
  open(path: string, text: string) {
    return this.send(["open", path, text]);
  }

  /** A byte-offset edit, as the engine API gives them ({pos, del, ins}, UTF-8 bytes). */
  change(path: string, pos: number, del: number, ins: string) {
    return this.send(["change", path, pos, del, ins]);
  }

  /** The last page in view: TeXpresso reports as soon as it has typeset this far. */
  goal(page: number) {
    if (page === this.lastGoal) return;
    this.lastGoal = page;
    this.send(["goal", page]);
  }

  /** Writes the SyncTeX data (plain text) to path; resolves once written. */
  synctex(path: string) {
    const id = ++this.seq;
    return new Promise<Record<string, unknown>>((res) => {
      this.waiting.set(id, res);
      this.send(["synctex", id, path]);
    });
  }

  /** Same answer as render/pdfrender's: {ok, w, h, cpu_us}. Page is 0-based. */
  render(page: number, scale: number, x: number, y: number, w: number, h: number, rgb: string, z: string) {
    const id = ++this.seq;
    return new Promise<Record<string, unknown>>((res) => {
      this.waiting.set(id, res);
      this.send(["render", id, page, scale, x, y, w, h, rgb, z]);
    });
  }

  kill() {
    try {
      this.proc.kill();
    } catch { /* gone */ }
  }
}
