// Writes the bench documents into OUT: long/ (26+ pages of plain paragraphs in the source, so edits land in text)
// and paper/ (a real-looking two-column-free article: abstract, sections, equations, figures, a table,
// cross-references and a natbib bibliography with its .bbl made by tectonic, since TeXpresso never runs bibtex).
//
//   deno run -A make-docs.ts OUT

import { join } from "jsr:@std/path@1";

const out = String(Deno.args[0]);
const WORDS = (
  "lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor incididunt ut labore et dolore " +
  "magna aliqua enim ad minim veniam quis nostrud exercitation ullamco laboris nisi aliquip ex ea commodo " +
  "consequat duis aute irure in reprehenderit voluptate velit esse cillum fugiat nulla pariatur excepteur sint " +
  "occaecat cupidatat non proident sunt culpa qui officia deserunt mollit anim id est laborum curabitur pretium " +
  "tincidunt lacus nulla gravida orci a odio nullam varius turpis et commodo pharetra eros bibendum elit nec luctus"
).split(" ");
let seed = 42;
const rnd = () => ((seed = (seed * 1103515245 + 12345) % 2147483648) / 2147483648);
const word = () => WORDS[Math.floor(rnd() * WORDS.length)];
function sentence() {
  const n = 8 + Math.floor(rnd() * 14);
  const w = Array.from({ length: n }, word);
  w[0] = w[0][0].toUpperCase() + w[0].slice(1);
  return w.join(" ") + ".";
}
const para = (k = 5 + Math.floor(rnd() * 4)) => Array.from({ length: k }, sentence).join(" ");

// long: plain paragraphs, one per source line block
{
  const dir = join(out, "long");
  await Deno.mkdir(dir, { recursive: true });
  const body: string[] = [];
  for (let s = 1; s <= 16; s++) {
    body.push(`\\section{Section ${s}}`);
    for (let p = 0; p < 9; p++) body.push(para());
  }
  await Deno.writeTextFile(
    join(dir, "main.tex"),
    `\\documentclass[11pt]{article}\n\\usepackage[margin=1in]{geometry}\n\\begin{document}\n` +
      body.join("\n\n") + `\n\\end{document}\n`,
  );
}

// paper
{
  const dir = join(out, "paper");
  await Deno.mkdir(dir, { recursive: true });
  // a figure: a plot drawn as a PDF by tectonic from TikZ, then used as a plain image file
  const fig = `\\documentclass[tikz]{standalone}\\begin{document}\\begin{tikzpicture}
\\draw[->] (0,0) -- (6,0) node[right]{$t$}; \\draw[->] (0,0) -- (0,4) node[above]{$y$};
\\draw[thick,blue,domain=0:6,samples=80] plot (\\x,{2+1.5*sin(\\x*90)*exp(-0.2*\\x)});
\\draw[thick,red,dashed,domain=0:6,samples=80] plot (\\x,{1+0.4*\\x});
\\end{tikzpicture}\\end{document}\n`;
  await Deno.writeTextFile(join(dir, "fig-src.tex"), fig);
  const r = await new Deno.Command("tectonic", { args: ["-X", "compile", "fig-src.tex"], cwd: dir }).output();
  if (!r.success) throw new Error("figure: " + new TextDecoder().decode(r.stderr));
  await Deno.rename(join(dir, "fig-src.pdf"), join(dir, "plot.pdf"));
  await Deno.remove(join(dir, "fig-src.tex"));
  // a raster figure too
  await new Deno.Command("pdftoppm", { args: ["-png", "-r", "100", "-singlefile", "plot.pdf", "raster"], cwd: dir })
    .output();

  const bib: string[] = [];
  for (let i = 1; i <= 24; i++) {
    bib.push(`@article{ref${i},
  author = {${word()}, A. and ${word()}, B.},
  title = {${sentence().slice(0, -1)}},
  journal = {Journal of ${word()} studies},
  year = {${1990 + i}},
  volume = {${i}},
  pages = {${i * 10}--${i * 10 + 9}}
}`);
  }
  await Deno.writeTextFile(join(dir, "refs.bib"), bib.join("\n\n") + "\n");

  const cite = () => `\\citep{ref${1 + Math.floor(rnd() * 24)}}`;
  const p = () => para().replace(/\. /, `. As shown by ${cite()}, `);
  const sec: string[] = [];
  const names = ["Introduction", "Related work", "Method", "Experiments", "Results", "Discussion", "Conclusion"];
  names.forEach((name, s) => {
    const key = name.toLowerCase().replace(/ /g, "-");
    sec.push(`\\section{${name}}\\label{sec:${key}}`);
    for (let k = 0; k < 6; k++) {
      sec.push(p());
      if (k === 2) {
        sec.push(`Section~\\ref{sec:${names[(s + 2) % names.length].toLowerCase().replace(/ /g, "-")}} and
Figure~\\ref{fig:plot${s % 2}} make this precise, with Equation~\\eqref{eq:main${s}}:
\\begin{equation}\\label{eq:main${s}}
  \\mathcal{L}_{${s}}(\\theta) = \\sum_{i=1}^{N} \\log p_\\theta(x_i \\mid z_i) - \\beta\\, \\mathrm{KL}\\big(q(z) \\,\\|\\, p(z)\\big) + \\int_0^T \\! f(t)\\,dt.
\\end{equation}`);
      }
      if (k === 3 && s % 2 === 0) {
        sec.push(`\\begin{figure}[t]\\centering
\\includegraphics[width=0.7\\linewidth]{${s % 4 === 0 ? "plot.pdf" : "raster.png"}}
\\caption{${sentence()}}\\label{fig:plot${(s / 2) % 2}}
\\end{figure}`);
      }
      if (k === 4 && s === 3) {
        sec.push(`\\begin{table}[t]\\centering\\caption{${sentence()}}\\label{tab:main}
\\begin{tabular}{lrrr}\\toprule Method & A & B & C \\\\ \\midrule
Baseline & 71.2 & 64.0 & 58.3 \\\\ Ours & \\textbf{78.9} & \\textbf{69.4} & \\textbf{61.0} \\\\ \\bottomrule
\\end{tabular}\\end{table}
Table~\\ref{tab:main} summarises it.`);
      }
    }
  });
  await Deno.writeTextFile(
    join(dir, "main.tex"),
    `\\documentclass[11pt]{article}
\\usepackage[margin=1in]{geometry}
\\usepackage{amsmath,amssymb,graphicx,booktabs}
\\usepackage[numbers]{natbib}
\\usepackage{hyperref}
\\title{On the ${word()} of ${word()} ${word()}}
\\author{A. Author \\and B. Author}
\\begin{document}
\\maketitle
\\begin{abstract}
${para(4)}
\\end{abstract}
\\tableofcontents

${sec.join("\n\n")}

\\bibliographystyle{plainnat}
\\bibliography{refs}
\\end{document}
`,
  );
  // tectonic runs bibtex and the extra passes; keep the .bbl and .aux for TeXpresso
  const c = await new Deno.Command("tectonic", { args: ["-X", "compile", "--keep-intermediates", "main.tex"], cwd: dir })
    .output();
  if (!c.success) throw new Error("paper: " + new TextDecoder().decode(c.stderr));
  for (const f of ["main.pdf", "main.log", "main.out", "main.toc"]) await Deno.remove(join(dir, f)).catch(() => {});
}
console.log(`wrote ${out}/long and ${out}/paper`);
