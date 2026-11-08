# MIT. Source me: the TeX Live 2026 store tree, stock engines from build-engines.sh, pinned dates.
R=$HOME/code/lab/taudot-ref
export TL_ROOT=$R/texlive-2026/store-root
export TEXMFCNF=$TL_ROOT-cnf:$TL_ROOT/texmf-dist/web2c
export TEXSTORE_IMAGE=2026.1@r79468 TEXSTORE_ROOT=$TL_ROOT
export SOURCE_DATE_EPOCH=1700000000 FORCE_SOURCE_DATE=1
export UBUILD=$R/universal/build-2026 UBIN=$R/universal/bin UFMT=$R/universal/fmt-2026
export TEXFORMATS=.:$UFMT
export TAU_TLROOT=$TL_ROOT TAU_FETCH=$HOME/code/lab/taudot-wt/universal/clients/universal/tools/tl-fetch
export USTOCK=$R/universal/bin-static  # references: static stock engines
