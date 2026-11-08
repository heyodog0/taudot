// A fake collaborator: types phrases a character at a time, moves its cursor, sometimes deletes what it typed, and
// leaves one comment.

import type { Doc, Engine, User } from "./engine.ts";

export const BOT: User = { user_id: "u-bot", name: "Ada Lovelace", initials: "AL" };

const PHRASES = [
  " This follows from Lemma~2.",
  " See also \\cite{knuth1984}.",
  " We leave the general case to future work.",
  " Note that $n \\geq 1$ here.",
  " The bound is tight.",
  " (Thanks to the reviewers for this point.)",
];

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

export interface BotOptions {
  intervalMs: number;
  charMs: number;
  path?: string;
  /** Stop after this many rounds (round 2 comments, round 3 makes a tracked insertion): a test's quiet bot. */
  rounds?: number;
}

export async function runBot(engine: Engine, opts: BotOptions) {
  const doc = pickDoc(engine, opts.path);
  if (!doc) {
    console.error("bot: no .tex doc to edit");
    return;
  }
  const r = Math.random;
  let round = 0;
  let lastTyped: { end: number; len: number } | null = null;
  engine.setPresence(BOT, doc.doc_id, 0, null);
  engine.activity("connection", `${BOT.name} joined`, { user: BOT });
  await sleep(opts.intervalMs);

  while (!opts.rounds || round < opts.rounds) {
    round++;
    const text = engine.textOf(doc);
    const lines = text.split("\n");

    if (round === 2) {
      // comment on the first word of a body line
      const at = findLineEnd(lines, r, true);
      if (at !== null) {
        const lineStart = engine.byteLen(lines.slice(0, at.line).join("\n") + (at.line ? "\n" : ""));
        const word = lines[at.line].match(/[A-Za-z]{4,}/);
        if (word && word.index !== undefined) {
          const start = lineStart + engine.byteLen(lines[at.line].slice(0, word.index));
          engine.setPresence(BOT, doc.doc_id, start, null);
          engine.addComment(doc, start, start + engine.byteLen(word[0]), BOT, `Is "${word[0]}" the right word here?`);
        }
      }
    } else if (round === 3) {
      // a tracked insertion at the end of a body line, as a reviewer with track changes on
      const at = findLineEnd(lines, r, false);
      if (at !== null) {
        const pos = engine.byteLen(lines.slice(0, at.line + 1).join("\n"));
        const ins = " (citation needed)";
        engine.applyEdit(doc, [{ pos, del: 0, ins }], doc.seq, BOT, "remote", null);
        engine.track(doc, [{ pos, del: 0, ins }], [""], BOT);
        engine.rangesChanged(doc);
        engine.setPresence(BOT, doc.doc_id, pos + engine.byteLen(ins), null);
      }
    } else if (lastTyped && r() < 0.25) {
      // delete the last phrase it typed, one character at a time from the end
      let { end, len } = lastTyped;
      lastTyped = null;
      for (let i = 0; i < len; i++) {
        const cur = engine.textOf(doc);
        const bytes = engine.encode(cur);
        if (end <= 0 || end > bytes.length) break;
        let w = 1;
        while (w < end && (bytes[end - w] & 0xc0) === 0x80) w++;
        end -= w;
        engine.applyEdit(doc, [{ pos: end, del: w, ins: "" }], doc.seq, BOT, "remote", null);
        engine.setPresence(BOT, doc.doc_id, end, null);
        await sleep(opts.charMs / 2);
      }
      engine.activity("edit", `${BOT.name} deleted a sentence in ${doc.path}`, { doc_id: doc.doc_id, user: BOT });
    } else {
      const at = findLineEnd(lines, r, false);
      if (at !== null) {
        let pos = engine.byteLen(lines.slice(0, at.line + 1).join("\n"));
        engine.setPresence(BOT, doc.doc_id, pos, null);
        await sleep(400);
        const phrase = PHRASES[Math.floor(r() * PHRASES.length)];
        // Track our own insertion point through other people's edits by reading the presence the engine moves.
        for (const ch of phrase) {
          const pr = engine.presence.get(BOT.user_id);
          if (pr?.pos != null) pos = pr.pos;
          engine.applyEdit(doc, [{ pos, del: 0, ins: ch }], doc.seq, BOT, "remote", null);
          pos += engine.byteLen(ch);
          engine.setPresence(BOT, doc.doc_id, pos, null);
          await sleep(opts.charMs * (0.6 + r() * 0.8));
        }
        lastTyped = { end: pos, len: [...phrase].length };
        engine.activity("edit", `${BOT.name} typed "${phrase.trim()}" in ${doc.path}:${at.line + 1}`, {
          doc_id: doc.doc_id,
          user: BOT,
        });
      }
    }
    if (opts.rounds && round >= opts.rounds) break;
    await sleep(opts.intervalMs * (0.7 + r() * 0.6));
  }
  engine.activity("connection", `${BOT.name} is done (${round} rounds)`, { user: BOT });
}

function pickDoc(engine: Engine, path?: string): Doc | undefined {
  const docs = [...engine.docs.values()];
  if (path) return engine.byPath.get(path);
  return docs.find((d) => d.path === "main.tex") ?? docs.find((d) => d.path.endsWith(".tex")) ?? docs[0];
}

// A line of body text: not empty, not a comment, not a command-only line.
function findLineEnd(lines: string[], r: () => number, needWord: boolean): { line: number } | null {
  const begin = lines.findIndex((l) => l.includes("\\begin{document}"));
  const end = lines.findIndex((l) => l.includes("\\end{document}"));
  const cands: number[] = [];
  for (let i = begin + 1; i < (end < 0 ? lines.length : end); i++) {
    const l = lines[i].trim();
    if (!l || l.startsWith("%") || /^\\[a-zA-Z]+\*?(\{[^}]*\})?$/.test(l)) continue;
    if (needWord && !/[A-Za-z]{4,}/.test(l.replace(/\\[a-zA-Z]+/g, ""))) continue;
    cands.push(i);
  }
  if (!cands.length) return null;
  return { line: cands[Math.floor(r() * cands.length)] };
}
