// Prints the pages of a PDF as Kitty images in the normal screen (so they go into scrollback), one under another,
// each scaled to the terminal's width in cells. Then waits.   deno run -A inline-pages.ts PDF [PAGES]
const pdf = Deno.args[0], n = Number(Deno.args[1] ?? 8);
const { columns } = Deno.consoleSize();
const enc = new TextEncoder();
for (let p = 1; p <= n; p++) {
  const file = await Deno.makeTempFile({ suffix: ".png" });
  await new Deno.Command("pdftoppm", { args: ["-f", String(p), "-l", String(p), "-r", "150", "-png", "-singlefile", pdf, file.slice(0, -4)] }).output();
  // c= scales to the full width; the terminal picks the rows; the cursor ends up under the image
  Deno.stdout.writeSync(enc.encode(`\x1b_Ga=T,f=100,t=f,c=${columns},q=2;${btoa(file)}\x1b\\\r\n`));
}
setInterval(() => {}, 1 << 30); // stay, so the pane and its scrollback stay
