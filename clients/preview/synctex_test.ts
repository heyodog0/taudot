import { assert, assertEquals } from "jsr:@std/assert@1";
import { forward, inverse, readSyncTex, samePath } from "./synctex.ts";

// Compiles a small document with tectonic; word positions below come from `pdftotext -bbox` on the same output.
Deno.test({
  name: "synctex: inverse and forward search on tectonic output",
  ignore: !(await new Deno.Command("tectonic", { args: ["--version"], stdout: "null" }).output().then((r) => r.success,
    () => false)),
  async fn() {
    const dir = await Deno.makeTempDir();
    await Deno.copyFile(new URL("../mock-engine/example/main.tex", import.meta.url), `${dir}/main.tex`);
    const r = await new Deno.Command("tectonic", {
      args: ["-X", "compile", "--synctex", "main.tex"],
      cwd: dir,
      stdout: "null",
      stderr: "null",
    }).output();
    assert(r.success);
    const st = (await readSyncTex(`${dir}/main.synctex.gz`))!;
    assertEquals(st.pages.length, 1);
    const at = (x: number, y: number) => inverse(st, 0, x, y)?.line;
    assertEquals(at(200, 268), 9); // "Introduction"
    assertEquals(at(150, 302), 11); // "binomial", second typeset line, from source line 11
    assertEquals(at(180, 335), 13); // "Result"
    assertEquals(at(270, 357), 14); // "monotone"
    const f = forward(st, `${dir}/main.tex`, 13)!;
    assertEquals(f.page, 0);
    assert(f.y > 320 && f.y < 342, `y ${f.y}`);
    assertEquals(forward(st, "main.tex", 9)?.page, 0);
    await Deno.remove(dir, { recursive: true });
  },
});

Deno.test("samePath", () => {
  assert(samePath("/private/tmp/a/main.tex", "/tmp/a/main.tex"));
  assert(samePath("./sec/intro.tex", "/x/proj/sec/intro.tex"));
  assert(!samePath("/x/a.tex", "/x/b.tex"));
});
