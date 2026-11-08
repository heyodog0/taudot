// A long review for tests (--synthetic-review CHANGES,COMMENTS): tracked changes from three reviewers, in clusters
// (a few edits by one person on a line or two, minutes apart), plus some comments, spread over the first .tex doc's
// body. Deterministic (a fixed seed), so captures before and after a change see the same panel.

import type { Engine, User } from "./engine.ts";

export const REVIEWERS: User[] = [
  { user_id: "u-grace", name: "Grace Hopper", initials: "GH" },
  { user_id: "u-alan", name: "Alan Turing", initials: "AT" },
  { user_id: "u-emmy", name: "Emmy Noether", initials: "EN" },
];

const WORDS = ["clearly", "in fact", "robust", "the proposed", "notably", "simple", "careful", "(see below)", "again", "here"];

export function seedReview(engine: Engine, changes: number, comments: number) {
  const doc = [...engine.docs.values()].find((d) => d.path === "main.tex") ?? [...engine.docs.values()].find((d) => d.path.endsWith(".tex"));
  if (!doc) return;
  let s = 7;
  const rnd = () => ((s = (s * 1103515245 + 12345) & 0x7fffffff) / 0x7fffffff);
  const body = () => {
    const lines = engine.textOf(doc).split("\n");
    const b = lines.findIndex((l) => l.includes("\\begin{document}"));
    const e = lines.findIndex((l) => l.includes("\\end{document}"));
    const out: number[] = [];
    for (let i = b + 1; i < (e < 0 ? lines.length : e); i++) if (lines[i].trim().length > 30 && !lines[i].trim().startsWith("\\")) out.push(i);
    return { lines, out };
  };
  const lineStart = (lines: string[], i: number) => engine.byteLen(lines.slice(0, i).join("\n") + (i ? "\n" : ""));
  const t0 = Date.now() - 3 * 86400_000;
  let made = 0, cluster = 0;
  while (made < changes) {
    const { lines, out } = body();
    if (!out.length) break;
    const author = REVIEWERS[cluster % REVIEWERS.length];
    const at = out[Math.floor((cluster * 0.618 % 1) * out.length)];
    const n = Math.min(changes - made, 2 + Math.floor(rnd() * 5));
    const ts = t0 + cluster * 3600_000;
    for (let k = 0; k < n; k++) {
      const { lines: ls } = body();
      const row = Math.min(at + (k % 2), ls.length - 1);
      const text = ls[row];
      const words = [...text.matchAll(/[A-Za-z]{3,}/g)];
      if (!words.length) break;
      const w = words[Math.floor(rnd() * words.length)];
      const base = lineStart(ls, row);
      if (rnd() < 0.55) {
        const ins = " " + WORDS[Math.floor(rnd() * WORDS.length)];
        const pos = base + engine.byteLen(text.slice(0, w.index! + w[0].length));
        engine.applyEdit(doc, [{ pos, del: 0, ins }], doc.seq, author, "remote", null);
        engine.track(doc, [{ pos, del: 0, ins }], [""], author);
      } else {
        const pos = base + engine.byteLen(text.slice(0, w.index!));
        const del = engine.byteLen(w[0]);
        engine.applyEdit(doc, [{ pos, del, ins: "" }], doc.seq, author, "remote", null);
        engine.track(doc, [{ pos, del, ins: "" }], [w[0]], author);
      }
      doc.ranges[doc.ranges.length - 1].ts = ts + k * 60_000;
      made++;
    }
    cluster++;
  }
  for (let c = 0; c < comments; c++) {
    const { lines, out } = body();
    const row = out[Math.floor(((c + 0.5) / comments) * out.length)];
    const m = lines[row].match(/[A-Za-z]{5,}/);
    if (!m) continue;
    const start = lineStart(lines, row) + engine.byteLen(lines[row].slice(0, m.index!));
    engine.addComment(doc, start, start + engine.byteLen(m[0]), REVIEWERS[c % REVIEWERS.length], `Should "${m[0]}" stay? (${c + 1})`);
  }
  engine.rangesChanged(doc);
  console.log(`synthetic review: ${made} tracked changes in ${cluster} clusters, ${comments} comments in ${doc.path}`);
}

/** A few pages of plain prose LaTeX for the synthetic review: `deno run synthetic.ts FILE [PARAGRAPHS]`. */
export function syntheticTex(paragraphs = 40): string {
  const sentences = [
    "We study the behaviour of the estimator under mild assumptions on the data.",
    "The method converges quickly when the step size is chosen with some care.",
    "Previous work considered only the balanced case, which rarely holds in practice.",
    "Our experiments cover three datasets and two families of baselines.",
    "The results suggest that the gap closes as the number of samples grows.",
    "A careful reader will notice that the constant depends on the dimension.",
    "This observation motivates the variant introduced in the next section.",
    "We leave the analysis of the general setting to future work.",
  ];
  const out = ["\\documentclass{article}", "\\begin{document}", "\\section{Introduction}", ""];
  for (let p = 0; p < paragraphs; p++) {
    if (p > 0 && p % 8 === 0) out.push(`\\section{Part ${p / 8 + 1}}`, "");
    for (let k = 0; k < 4; k++) out.push(sentences[(p * 3 + k) % sentences.length]);
    out.push("");
  }
  out.push("\\end{document}", "");
  return out.join("\n");
}

if (import.meta.main) {
  const [file, n] = Deno.args;
  Deno.writeTextFileSync(file, syntheticTex(n ? Number(n) : 40));
}
