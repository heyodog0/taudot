#!/bin/bash
# Clip 3: Bob comments from his engine (an Overleaf comment), Alice replies in the card with real keys.
set -u
cd "$(dirname "$0")/../.."
ev() { nvim --server /tmp/td/nvim.sock --headless --remote-expr "$1" 2>&1; }
R() { target/debug/taudot rpc --home /tmp/tdb/home "$@"; }
P=$(cat /tmp/td/app.pid); WIN=$(sed -n 's/^Taudot: window //p' /tmp/td/app.log | head -1)
PREV=${PREV:-23291}
Q='$T_0 = 90^\circ$C'
R doc.open '{"project_id":"6aec2d934534e890b29388e3","path":"main.tex"}' > /tmp/tdb/doc.json
P3=$(node -e 'const fs=require("fs"); const t=JSON.parse(fs.readFileSync("/tmp/tdb/doc.json")).text; const q=process.argv[1]; const i=t.indexOf(q); if(i<0) process.exit(1); console.log(JSON.stringify({doc_id:"6aec2d934534e890b29388e7",start:i,end:i+q.length,text:"Is 90°C realistic? Most people wait a minute before the first sip."}))' "$Q") || { echo "no quote"; exit 1; }
ev "luaeval('(function() package.loaded[ [[taudot.app]] ].pause(false) return 1 end)()')" >/dev/null
/tmp/td/record $WIN 15 /tmp/td/raw/comment.mov > /tmp/td/rec3.log 2>&1 & RP=$!
for i in $(seq 40); do grep -q recording /tmp/td/rec3.log && break; sleep 0.1; done
sleep 1
R comment.add "$P3" >/dev/null
sleep 2.2
# Alice: cursor into the commented text, the app in front, then ⌥⌘↩ (Reply) and the reply
ev "luaeval('(function() local ls=vim.api.nvim_buf_get_lines(0,0,-1,false) for n,l in ipairs(ls) do local s=l:find([[90^]],1,true) if s then vim.api.nvim_win_set_cursor(0,{n,s}) return n end end end)()')" >/dev/null
uvx --quiet --with pyobjc-framework-ApplicationServices --with pyobjc-framework-Cocoa python -I site/demo/raise.py $P
sleep 0.15
/tmp/td/keys $P "Fair. I will rerun it with 80°C."
wait $RP; cat /tmp/td/rec3.log
osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $PREV) to true" 2>/dev/null
R thread.list '{"project_id":"6aec2d934534e890b29388e3"}' | jq -c '.threads[] | [.text, [.messages[] | .text]]'
