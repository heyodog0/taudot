#!/bin/bash
# Query Kitty graphics support, then try to draw a PNG.
exec </dev/tty
old=$(stty -g); stty raw -echo min 0 time 15
printf '\e_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\e\\\e[c'
resp=""; while IFS= read -r -n1 c; do resp+="$c"; [[ "$resp" == *c ]] && [[ "$resp" == *"[?"* ]] && break; done
stty "$old"
echo "raw reply: $(printf '%q' "$resp")"
if [[ "$resp" == *"_Gi=31;OK"* ]]; then echo "KITTY GRAPHICS: SUPPORTED"; else echo "KITTY GRAPHICS: no reply (unsupported)"; fi
data=$(base64 < "$1" | tr -d '\n'); first=1
while [ -n "$data" ]; do chunk=${data:0:4096}; data=${data:4096}; m=$([ -n "$data" ] && echo 1 || echo 0)
  if [ $first = 1 ]; then printf '\e_Ga=T,f=100,m=%s;%s\e\\' "$m" "$chunk"; first=0; else printf '\e_Gm=%s;%s\e\\' "$m" "$chunk"; fi; done
echo; echo "(image above if drawn)"
