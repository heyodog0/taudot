// Pairs keystroke times (JSON lines {key, t} on stdin) with the preview trace: first "drawn" of the changed page
// after each keystroke, and the compile/typeset report before it.
//   deno run -A analyze-trace.ts TRACE LABEL [RESULTS] < keys
const [tracePath, label, results] = Deno.args;
const keys = (await new Response(Deno.stdin.readable).text()).trim().split("\n").filter((l) => l.startsWith("{"))
  .map((l) => JSON.parse(l)).filter((k) => k.key !== undefined);
const ev = (await Deno.readTextFile(tracePath)).trim().split("\n").map((l) => JSON.parse(l));
const rows = keys.map((k, i) => {
  const end = keys[i + 1]?.t ?? k.t + 3000;
  const d = ev.find((e) => e.ev === "drawn" && e.t > k.t && e.t < end);
  const c = ev.find((e) => e.ev === "compile_end" && e.t > k.t && e.t < end);
  return { drawn: d ? d.t - k.t : NaN, report: c ? c.t - k.t : NaN, tiles: d?.tiles ?? false };
});
const ok = rows.filter((r) => !isNaN(r.drawn)).map((r) => r.drawn).sort((a, b) => a - b);
const s = {
  label,
  keys: rows.length,
  drawn: ok.length,
  median_ms: ok[Math.floor(ok.length / 2)],
  min_ms: ok[0],
  max_ms: ok.at(-1),
  report_median_ms: rows.map((r) => r.report).filter((x) => !isNaN(x)).sort((a, b) => a - b)[Math.floor(rows.length / 2)],
  per_key: rows.map((r) => `${r.drawn}${r.tiles ? "t" : ""}`).join(" "),
};
console.log(JSON.stringify(s));
if (results) await Deno.writeTextFile(results, JSON.stringify(s) + "\n", { append: true });
