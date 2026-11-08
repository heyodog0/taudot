// CPU and wall time per 512x512 tile: pdftoppm (one process per tile, as the preview did) vs the pdfrender daemon.
//   deno run -A render-bench.ts PDF [SCALE] [TILES]
const pdf = Deno.args[0], scale = Number(Deno.args[1] ?? 4.93), n = Number(Deno.args[2] ?? 24);
const here = new URL(".", import.meta.url).pathname;
const tmp = await Deno.makeTempDir();
const rects = Array.from({ length: n }, (_, i) => ({ x: (i % 5) * 512, y: Math.floor(i / 5) * 512 }));
const dec = new TextDecoder();

// pdftoppm: /usr/bin/time -p reports user+sys of the child
let ppCpu = 0;
const t0 = performance.now();
for (const r of rects) {
  const res = await new Deno.Command("/usr/bin/time", {
    args: ["-p", "pdftoppm", "-f", "1", "-l", "1", "-r", String(scale * 72), "-x", String(r.x), "-y", String(r.y), "-W", "512", "-H", "512", "-singlefile", pdf],
    stdout: "null", stderr: "piped",
  }).output();
  const e = dec.decode(res.stderr);
  ppCpu += Number(e.match(/user\s+([\d.]+)/)?.[1] ?? 0) + Number(e.match(/sys\s+([\d.]+)/)?.[1] ?? 0);
}
const ppWall = performance.now() - t0;

// daemon
const d = new Deno.Command(`${here}pdfrender`, { stdin: "piped", stdout: "piped" }).spawn();
const w = d.stdin.getWriter(), rd = d.stdout.pipeThrough(new TextDecoderStream()).getReader();
let buf = "";
async function ask(o: unknown) {
  await w.write(new TextEncoder().encode(JSON.stringify(o) + "\n"));
  while (!buf.includes("\n")) buf += (await rd.read()).value ?? "";
  const i = buf.indexOf("\n"), line = buf.slice(0, i);
  buf = buf.slice(i + 1);
  return JSON.parse(line);
}
await ask({ id: 0, op: "open", path: pdf });
let dCpu = 0;
const t1 = performance.now();
for (const [i, r] of rects.entries()) {
  const res = await ask({ id: i + 1, op: "render", page: 1, scale, x: r.x, y: r.y, w: 512, h: 512, rgb: `${tmp}/t.rgb`, z: `${tmp}/t.z` });
  dCpu += res.cpu_us / 1e6;
}
const dWall = performance.now() - t1;
await w.close();
await d.status;
await Deno.remove(tmp, { recursive: true });
const f = (v: number) => Math.round(v * 10) / 10;
console.log(JSON.stringify({
  tiles: n, scale,
  pdftoppm: { cpu_ms_per_tile: f((ppCpu * 1000) / n), wall_ms_per_tile: f(ppWall / n), note: "PPM only, no zlib" },
  pdfrender: { cpu_ms_per_tile: f((dCpu * 1000) / n), wall_ms_per_tile: f(dWall / n), note: "RGB + zlib files" },
}, null, 2));
