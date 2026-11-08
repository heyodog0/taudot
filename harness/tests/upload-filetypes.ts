#!/usr/bin/env node
// Which uploaded text files become editable docs and which become binary files (round 1: sections/unicode.tex
// "seeds as a binary file"). FileTypeManager.isEditable refuses any surrogate (non-BMP character) or NUL, so the
// first seed, whose unicode.tex had emoji, made it a binary file. testbed moved the emoji to astral.tex.
import { mkdtempSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { Check, client, project } from './common.ts'

const check = new Check('upload-filetypes')
const dir = mkdtempSync(join(tmpdir(), 'taudot-types-'))
const files: Record<string, string | Buffer> = {
  'main.tex': '\\documentclass{article}\\begin{document}x\\end{document}\n',
  'bmp.tex': 'café αβγ 日本語 € �\n',
  'emoji.tex': 'one emoji 😀\n',
  'mathletter.tex': 'one 𝔸\n',
  'nul.tex': 'a\0b\n',
  'latin1.tex': Buffer.from([0x63, 0x61, 0x66, 0xe9, 0x0a]), // "café" in ISO-8859-1
}
for (const [n, c] of Object.entries(files)) writeFileSync(join(dir, n), c)
const pid = project('protocol filetypes', { reset: true, from: dir })
const c = await client(1, pid)
const root = c.project.rootFolder[0]
const docs = root.docs.map((d: any) => d.name).sort()
const binaries = root.fileRefs.map((f: any) => f.name).sort()
check.note('docs', docs)
check.note('binaries', binaries)
check.that(JSON.stringify(docs) === JSON.stringify(['bmp.tex', 'latin1.tex', 'main.tex']), 'BMP-only and Latin-1 files are docs')
check.that(JSON.stringify(binaries) === JSON.stringify(['emoji.tex', 'mathletter.tex', 'nul.tex']), 'astral or NUL makes a binary file')
const latin1 = await c.joinDoc(root.docs.find((d: any) => d.name === 'latin1.tex')._id)
check.note('latin1Text', decodeURIComponent(escape(latin1.lines.join('\n'))))
check.that(decodeURIComponent(escape(latin1.lines.join('\n'))) === 'café\n', 'Latin-1 upload is decoded to café')
c.close()
check.done()
