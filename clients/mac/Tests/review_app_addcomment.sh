#!/bin/sh
# Add a comment in the real app (taudot-app, debug build) against the mock engine, three ways: a `v` selection and
# ⌥⌘M, a `V` selection and <prefix>c (<leader>ac), a mouse drag and a click on the Comment pill. Each across a
# wrapped line and the next. Checks the pill's place, the draft's quote, Return sending, and the comment's range as
# the engine anchored it.
#   swift build --product taudot-app && clients/mac/Tests/review_app_addcomment.sh [OUTDIR]
# HIDDEN=1: the margin hidden (this temp folder's pane defaults, removed after): the draft floats at the selection.
# Opt-in (TAUDOT_ONSCREEN=1): comes to the front for ~30 s (keys need the key window). Events go to the app's process only (CGEventPostToPid).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/review_lib.sh"
txs_onscreen_only "typed keys and clicks with the app in front"
MAC=$(cd "$HERE/.." && pwd)
REPO=$(cd "$MAC/../.." && pwd)
W=$(mktemp -d)
txs_on_exit 'rm -f "$ES" "$NS"; rm -rf "$W/proj"; [ "${HIDDEN:-0}" = 1 ] && defaults delete taudot-app "$KEY" 2>/dev/null'
OUT=${1:-$W/out}
mkdir -p "$OUT" "$W/proj"
cp "$REPO/clients/mock-engine/example/main.tex" "$W/proj/main.tex"
ES=/tmp/txs-margin-ac$$.sock
NS=/tmp/txs-margin-acn$$.sock
PY="uvx --quiet --with pyobjc-framework-Quartz --with pyobjc-framework-ApplicationServices python -I"
deno run -A "$REPO/clients/mock-engine/main.ts" --folder "$W/proj" --socket "$ES" >"$W/mock.log" 2>&1 &
MOCK=$!
txs_track $MOCK
i=0; while [ ! -S "$ES" ] && [ $i -lt 100 ]; do i=$((i+1)); sleep 0.1; done
# A seed comment so the margin shows; a server socket to ask Neovim things.
EXEC="vim.fn.serverstart('$NS'); vim.g.e2e_reloads = {}; vim.api.nvim_create_autocmd({'BufReadPost','FileChangedShellPost','FocusGained','FocusLost'}, {callback=function(a) local t = vim.g.e2e_reloads; t[#t+1] = a.event; vim.g.e2e_reloads = t end}); vim.defer_fn(function() require('taudot.gui').act('comment', nil, {text='seed', line=1, col=0, end_line=1, end_col=5}) end, 500)"
KEY="taudot.panes.$W/proj"
[ "${HIDDEN:-0}" = 1 ] && defaults write taudot-app "$KEY" -dict marginHidden -bool true marginManual -bool true pdfHidden -bool true
TAUDOT_SOCKET="$ES" TAUDOT_NO_PDF=1 TAUDOT_DEBUG=1 TAUDOT_EXEC="$EXEC" "$MAC/.build/debug/taudot-app" "$W/proj" >"$W/app.log" 2>&1 &
APP=$!
txs_track $APP
i=0; while [ ! -S "$NS" ] && [ $i -lt 300 ]; do i=$((i+1)); sleep 0.1; done
[ -S "$NS" ] || { echo "FAIL no nvim server"; exit 1; }
ev() { nvim --server "$NS" --headless --remote-expr "$1" 2>&1; }
lua() { ev "luaeval('$1')"; }
sleep 3
fails=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=$((fails+1)); }

# A line long enough to wrap, after a line with text: the selection runs from inside it to the next line.
ROW=$(lua "(function() local ls = vim.api.nvim_buf_get_lines(0,0,-1,false) for i=#ls-1,1,-1 do if #ls[i]>45 and #ls[i+1]>10 and not ls[i]:match([[^\\\\\\\\]]) then vim.api.nvim_buf_set_lines(0,i-1,i,false,{ls[i]..[[ This sentence is long on purpose, so that the line wraps in the editor at any window width a laptop gives it, twice or more, really.]]}) return i-1 end end end)()")
sleep 1
WIN=""; i=0; while [ -z "$WIN" ] && [ $i -lt 50 ]; do WIN=$(sed -n 's/^taudot: window //p' "$W/app.log" | head -1); i=$((i+1)); sleep 0.1; done
POSN="(function() local o={} for _,it in ipairs(require([[taudot.gui]]).payload().items) do o[#o+1]=it.line..[[:]]..it.col..[[-]]..it.end_line..[[:]]..it.end_col end return table.concat(o,[[ ]])..[[ autoread=]]..tostring(vim.o.autoread)..[[ tick=]]..vim.b.changedtick end)()"
echo "     items before focus: $(lua "$POSN")"
osascript -e 'tell application "System Events" to set frontmost of (first process whose unix id is '"$APP"') to true' >/dev/null 2>&1
sleep 0.5
echo "     items after focus:  $(lua "$POSN")"

for MODE in v V mouse; do
  case $MODE in v) TAG=char;; V) TAG=line;; *) TAG=mouse;; esac  # file names: the disk may not tell v from V
  lua "(function() vim.cmd([[normal! \\27]]) require([[taudot.gui]]).act([[select]], nil) vim.api.nvim_win_set_cursor(0,{$ROW+1,0}) vim.cmd([[normal! zt]]) end)()" >/dev/null
  sleep 0.4
  F=$($PY "$HERE/review_ax_frames.py" $APP)
  # The editor's frame (between the first two splitters, under the split group's top) and its cell size.
  GRID=$(lua "vim.o.lines .. [[ ]] .. vim.o.columns")
  case $MODE in
    v) lua "(function() vim.api.nvim_win_set_cursor(0,{$ROW+1,4}) vim.api.nvim_feedkeys([[v]],[[nx]],false) vim.api.nvim_win_set_cursor(0,{$ROW+2,5}) end)()" >/dev/null ;;
    V) lua "(function() vim.api.nvim_win_set_cursor(0,{$ROW+1,0}) vim.api.nvim_feedkeys([[Vj]],[[nx]],false) end)()" >/dev/null ;;
    mouse)
      P=$(lua "(function() local a=vim.fn.screenpos(0,$ROW+1,5) local b=vim.fn.screenpos(0,$ROW+2,6) return a.row..[[ ]]..a.col..[[ ]]..b.row..[[ ]]..b.col end)()")
      PTS=$(uv run --no-project python -I -c "
import json,sys
f=json.loads(sys.argv[1]); lines,cols=map(int,sys.argv[2].split()); ar,ac,br,bc=map(int,sys.argv[3].split())
s=f['split']; sp=sorted(f['splitters'])
left=sp[0][0]+1; right=sp[1][0] if len(sp)>1 else s[0]+s[2]; top=s[1]; h=s[3]
cw=(right-left)/cols; ch=h/lines
print(f'{left+(ac-0.5)*cw:.0f},{top+(ar-0.5)*ch:.0f} {left+(bc-0.5)*cw:.0f},{top+(br-0.5)*ch:.0f}')" "$F" "$GRID" "$P")
      $PY "$HERE/review_events.py" $APP drag $PTS ;;
  esac
  sleep 0.7
  STATE=$(lua "(function() local v=require([[taudot.gui]]).visual() if not v then return [[none]] end return table.concat({v.line,v.col,v.end_line,v.end_col,v.end_wrap or -1,v.end_screen_col or -1},[[ ]]) end)()")
  WANT=$(lua "(function() local v=require([[taudot.gui]]).visual() if not v then return [[]] end return table.concat(vim.api.nvim_buf_get_text(0,v.line,v.col,v.end_line,v.end_col,{}),[[ ]]) end)()")
  ENDROW=$(lua "(function() local v=require([[taudot.gui]]).visual() if not v then return 0 end return vim.fn.screenpos(0,v.end_line+1,math.max(1,v.end_col)).row end)()")
  F=$($PY "$HERE/review_ax_frames.py" $APP)
  CHECK=$(uv run --no-project python -I -c "
import json,sys
f=json.loads(sys.argv[1]); lines,cols=map(int,sys.argv[2].split()); st=sys.argv[3].split(); endrow=int(sys.argv[4])
if 'pill' not in f: print('nopill'); sys.exit()
s=f['split']; sp=sorted(f['splitters'])
left=sp[0][0]+1; right=sp[1][0] if len(sp)>1 else s[0]+s[2]; top=s[1]; h=s[3]
cw=(right-left)/cols; ch=h/lines
px,py,pw,ph=f['pill']
ey=top+endrow*ch+4                     # just below the end's screen row
ex=min(max(left+8, left+int(st[5])*((right-left)/cols)-12), right-pw-8)
print(f'pill at {px:.0f},{py:.0f}; want {ex:.0f},{ey:.0f}; off {px-ex:+.1f},{py-ey:+.1f} pt (cell {cw:.1f}x{ch:.1f})')
print('near' if abs(py-ey) <= ch/2 and abs(px-ex) <= cw else 'far')" "$F" "$GRID" "$STATE" "$ENDROW")
  echo "[$MODE] selection $STATE; $CHECK" | tr '\n' ' '; echo
  case "$CHECK" in *near*) ok "$MODE: pill under the end of the selection";; *) bad "$MODE: pill: $CHECK";; esac
  screencapture -x -o -l"$WIN" "$OUT/app-$TAG-pill.png"
  # Start the draft.
  case $MODE in
    v) $PY "$HERE/review_events.py" $APP key 46 cmd,opt ;;
    V) lua "vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(require([[taudot.config]]).options.mapping_prefix .. [[c]], true, false, true), [[m]], false)" >/dev/null ;;
    mouse) PC=$(uv run --no-project python -I -c "import json,sys; x,y,w,h=json.loads(sys.argv[1])['pill']; print(f'{x+w/2:.0f},{y+h/2:.0f}')" "$F"); $PY "$HERE/review_events.py" $APP click "$PC" ;;
  esac
  for _ in 1 2 3 4 5 6; do
    sleep 0.4
    F=$($PY "$HERE/review_ax_frames.py" $APP)
    case "$F" in *field*) break;; esac
  done
  case "$F" in *field*) ok "$MODE: the draft opened";; *) bad "$MODE: no draft field: $F"; continue;; esac
  if [ "${HIDDEN:-0}" = 1 ]; then
    # The floating draft: its field over the editor, under the selection's last row, near where the pill was.
    WHERE=$(uv run --no-project python -I -c "
import json,sys
f=json.loads(sys.argv[1]); lines,cols=map(int,sys.argv[2].split()); endrow=int(sys.argv[3])
s=f['split']; ch=s[3]/lines; fx,fy,fw,fh=f['field']; rowb=s[1]+endrow*ch
print(f'field at {fx:.0f},{fy:.0f}, end row bottom {rowb:.0f}', 'over' if s[0] <= fx <= s[0]+s[2] and rowb <= fy <= rowb+140 else 'away')" "$F" "$GRID" "$ENDROW")
    case "$WHERE" in *over) ok "$MODE: the draft floats under the selection ($WHERE)";; *) bad "$MODE: floating draft: $WHERE";; esac
  fi
  [ "$(lua 'vim.api.nvim_get_mode().mode')" = "n" ] && ok "$MODE: Neovim left visual mode" || bad "$MODE: mode $(lua 'vim.api.nvim_get_mode().mode')"
  TEXT="Comment by $MODE"
  $PY "$HERE/review_events.py" $APP type "$TEXT"
  sleep 0.3
  screencapture -x -o -l"$WIN" "$OUT/app-$TAG-draft.png"
  $PY "$HERE/review_events.py" $APP key 36
  sleep 1.5
  SEL=$(echo "$STATE" | cut -d' ' -f1-4)
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    GOT=$(lua "(function() for _,it in ipairs(require([[taudot.gui]]).payload().items) do if it.messages[1] and it.messages[1].text==[[$TEXT]] then return table.concat({it.line,it.col,it.end_line,it.end_col},[[ ]])..[[|]]..(it.quote:gsub(string.char(10),[[ ]])) end end return [[none]] end)()")
    [ "${GOT%%|*}" = "$SEL" ] && break
    sleep 0.3
  done

  [ "${GOT%%|*}" = "$SEL" ] && ok "$MODE: anchored on the selection ($SEL)" || {
    bad "$MODE: anchored at ${GOT%%|*}, selection $SEL"
    echo "     events: $(lua 'table.concat(vim.g.e2e_reloads, [[ ]])')"
    lua "(function() local o={} for _,it in ipairs(require([[taudot.gui]]).payload().items) do o[#o+1]=it.id..[[ ]]..it.kind..[[ ]]..it.line..[[:]]..it.col..[[-]]..it.end_line..[[:]]..it.end_col..[[ ]]..((it.messages[1] or {}).text or [[]]) end return table.concat(o,[[ / ]]) end)()"
  }
  [ "${GOT#*|}" = "$WANT" ] && ok "$MODE: quote is the selected text" || bad "$MODE: quote '${GOT#*|}' want '$WANT'"
  # The engine's own anchor (byte offsets) for that thread, against the selection's.
  OFFS=$(lua "(function() local s=vim.split([[$SEL]],[[ ]]) return (vim.api.nvim_buf_get_offset(0,tonumber(s[1]))+tonumber(s[2]))..[[ ]]..(vim.api.nvim_buf_get_offset(0,tonumber(s[3]))+tonumber(s[4])) end)()")
  ENG=$(deno run -A "$HERE/review_mock_threads.ts" "$ES" | uv run --no-project python -I -c "
import json,sys
r=json.load(sys.stdin); t=[t for t in r.get('threads',[]) if t.get('messages') and t['messages'][0].get('text')==sys.argv[1]]
print(f\"{t[0]['start']} {t[0]['end']}\" if t else 'none')" "$TEXT")
  [ "$ENG" = "$OFFS" ] && ok "$MODE: the engine anchored it at bytes $ENG" || bad "$MODE: engine anchor $ENG, selection bytes $OFFS"
  [ "$(lua 'vim.api.nvim_get_mode().mode')" = "n" ] && ok "$MODE: back in the editor" || true
  screencapture -x -o -l"$WIN" "$OUT/app-$TAG-sent.png"
done
echo "screenshots: $OUT"
[ $fails -eq 0 ] && echo "all ok" || echo "$fails failed"
