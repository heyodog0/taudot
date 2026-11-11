mod glyphs;
mod layout;
mod pdf;
mod prove;
mod texgen;
mod math;
mod texmf;

use std::process::exit;

fn usage() -> ! {
    eprintln!(
        "pdfsource dump FILE.pdf [PAGE]        glyphs per page (debug)\n\
         pdfsource lines FILE.pdf [PAGE]       lines and paragraphs found\n\
         pdfsource prove FILE.pdf [--json]     re-typeset every paragraph and compare\n\
         pdfsource tex FILE.pdf               the recovered LaTeX, each paragraph marked proven or approximate"
    );
    exit(2)
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.len() < 2 {
        usage();
    }
    let mut pdf = match pdf::Pdf::open(&args[1]) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("{e}");
            exit(1)
        }
    };
    let only: Option<usize> = args.get(2).and_then(|s| s.parse().ok());
    match args[0].as_str() {
        "dump" => {
            for n in 1..=pdf.page_count() {
                if only.is_some_and(|o| o != n) {
                    continue;
                }
                let p = pdf.page(n).unwrap();
                println!("page {n} {}x{} glyphs {} rules {} graphics {}", p.width, p.height, p.glyphs.len(), p.rules.len(), p.graphics);
                for r in &p.rules {
                    println!("rule {:9.3} {:9.3} {:9.3} {:9.3}", r.x0, r.y0, r.x1, r.y1);
                }
                for g in &p.glyphs {
                    let f = &pdf.fonts[g.font];
                    println!(
                        "{:9.3} {:9.3} {:7.3} {:6.3} {:5.3} {:24} {:3} {:12} {:?}",
                        g.x, g.y, g.adv, g.size, g.hscale, f.name, g.code,
                        f.names.get(&g.code).map(|s| s.as_str()).unwrap_or("?"),
                        layout::glyph_text(f, g.code)
                    );
                }
            }
        }
        "lines" => {
            let doc = layout::analyze(&mut pdf, only);
            layout::print(&pdf, &doc);
        }
        "tex" => {
            let doc = layout::analyze(&mut pdf, only);
            let report = prove::prove(&pdf, &doc, &args[1]);
            print!("{}", prove::write_tex(&report, &doc));
        }
        "prove" => {
            let json = args.iter().any(|a| a == "--json");
            let doc = layout::analyze(&mut pdf, only);
            let report = prove::prove(&pdf, &doc, &args[1]);
            prove::print(&report, json);
        }
        _ => usage(),
    }
}
