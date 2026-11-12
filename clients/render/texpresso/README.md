# Our patches to TeXpresso

Upstream TeXpresso (`github.com/let-def/texpresso`, MIT, © 2023 Frédéric Bour) at `e8df770`, plus `patches/`. Files
the patches add (`taudot-pic.*`, `taudot-fonts.*`) are ours, MIT.

    sh clients/render/texpresso/apply.sh DIR     # clone, check out the pin, git am the series (branch taudot)
    make -C DIR -j8 all                          # texpresso-xetex and the frontend objects
    TEXPRESSO_DIR=DIR sh clients/render/build.sh # txp-render

Engine (`00NN`): `0001` snapshot interval macro; `0002` clipped figures; `0003` input seek offset; `0004` PDF boxes
and image sizes via Core Graphics, no dvipdfmx; `0005` the TeX bundle's fonts by name (`fonts/make_index.py`);
`0006` `taudot-pdfinfo` helper, shipped beside `texpresso-xetex`.

Drawing (`01NN`): `0101` dashes; `0102` opacity and transparency groups; `0103` CMYK; `0104` initial line width and
miter; `0105` tiling patterns; `0106` shadings; `0107` two-factor `x:scale`; `0108` `pdf:literal direct`, `pdf:content`.

Tests: `tests/<name>/`, run with `tests/compare.py` (against `mutool`) or `tests/same.py` (two builds).
