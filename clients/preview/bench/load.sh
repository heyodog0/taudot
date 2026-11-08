#!/bin/sh
# renders tiles in a loop like a scrolling preview: 3 pdftoppm at a time, 4 s
end=$(($(date +%s) + 4))
while [ $(date +%s) -lt $end ]; do
  for k in 1 2 3; do pdftoppm -f 3 -l 3 -r 280 -x 0 -y $((k*512)) -W 2900 -H 1024 -singlefile ${1:?usage: load.sh PDF} >/dev/null & done; wait
done
