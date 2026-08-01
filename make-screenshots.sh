#!/usr/bin/env bash
# make-screenshots.sh — regenerate screenshots/<theme>.html from the real dashboard.
#
# The screenshots in this repo were previously produced by hand, so nothing recorded how, and
# the window chrome was hardcoded dark (#1e1e2e) regardless of the theme. That made a LIGHT
# theme impossible to show honestly: dark ink on a dark card is unreadable, which is not a
# property of the theme, only of the frame around it.
#
# This renders each theme through the actual dashboard.sh with a FIXED synthetic payload — no
# live network, no real account — converts the ANSI to HTML, and picks the window chrome from
# the theme's own class. Deterministic input matters: a screenshot generated from live data
# changes every run and leaks whatever the machine happened to know.
#
# Usage:  ./make-screenshots.sh [theme ...]     (default: all)
set -o pipefail

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
OUT=screenshots
mkdir -p "$OUT"

# Themes whose foregrounds are DARK ink meant for a light page.
LIGHT_THEMES=" light solarized-light paper "

DARK_THEMES="terminal-green solarized nord cyberpunk minimal batman iron-man dbz evangelion
ghost-in-shell akira spider-verse blade-runner one-piece ghibli nebula mythos netrunner
rainforest garden terrarium harvest"

ALL="$DARK_THEMES light solarized-light paper"

# Fixed payload. Placeholder identity ONLY — the previous screenshots shipped a real city.
read -r -d '' PAYLOAD <<'JSON'
{"session_id":"demo","cwd":"/home/user/project","version":"2.1.220",
 "model":{"display_name":"Opus 5"},
 "cost":{"total_cost_usd":12.34,"total_duration_ms":5400000},
 "context_window":{"context_window_size":1000000,
   "current_usage":{"input_tokens":48000,"cache_read_input_tokens":122000}}}
JSON

ansi_to_html() {
  python3 - "$1" <<'PY'
import re, sys, html
SGR = re.compile(r'\x1b\[([0-9;]*)m')
BASE = {30:"#000000",31:"#cc0000",32:"#4e9a06",33:"#c4a000",34:"#3465a4",35:"#75507b",
        36:"#06989a",37:"#d3d7cf",90:"#555753",91:"#ef2929",92:"#8ae234",93:"#fce94f",
        94:"#729fcf",95:"#ad7fa8",96:"#34e2e2",97:"#eeeeec"}
text = sys.stdin.read()
out, color, bold, open_span = [], None, False, False
def close():
    global open_span
    if open_span: out.append("</span>"); open_span=False
def openspan():
    global open_span
    st=[]
    if color: st.append(f"color:{color}")
    if bold: st.append("font-weight:600")
    if st: out.append(f'<span style="{";".join(st)}">'); open_span=True
pos=0
for m in SGR.finditer(text):
    seg = text[pos:m.start()]
    if seg:
        if not open_span: openspan()
        out.append(html.escape(seg))
    pos = m.end()
    codes = [int(c) for c in (m.group(1) or "0").split(";") if c != ""] or [0]
    close()
    i=0
    while i < len(codes):
        c = codes[i]
        if c == 0: color=None; bold=False
        elif c == 1: bold=True
        elif c == 22: bold=False
        elif c == 38 and i+4 < len(codes) and codes[i+1] == 2:
            color = "#%02x%02x%02x" % (codes[i+2], codes[i+3], codes[i+4]); i += 4
        elif c in BASE: color = BASE[c]
        i += 1
seg = text[pos:]
if seg:
    if not open_span: openspan()
    out.append(html.escape(seg))
close()
sys.stdout.write("".join(out))
PY
}

render() {
  local theme="$1" is_light=0
  case "$LIGHT_THEMES" in *" $theme "*) is_light=1 ;; esac

  # UNIFORM CHROME — exactly two frames, one per theme class, never per-theme.
  # Varying the window colour with each theme was the first thing I tried and it is wrong:
  # the frame stops being a neutral reference, so themes cannot be compared side by side in
  # the README and any contrast claim becomes per-image rather than a property of the set.
  # One light frame, one dark frame, and every theme's contrast is measured against its
  # frame by check-contrast.py rather than eyeballed.
  local win bar dotr doty dotg shadow
  if [ "$is_light" -eq 1 ]; then
    win="#ffffff"; bar="#e8eaed"; dotr="#ea4335"; doty="#fbbc04"; dotg="#34a853"
    shadow="0 4px 20px rgba(60,64,67,0.20)"
  else
    win="#1e1e2e"; bar="#313244"; dotr="#f38ba8"; doty="#f9e2af"; dotg="#a6e3a1"
    shadow="0 4px 20px rgba(0,0,0,0.4)"
  fi

  local body
  body=$(printf '%s' "$PAYLOAD" | DASHBOARD_THEME="$theme" DASHBOARD_TEMP_UNIT=F \
           DASHBOARD_CACHE_DIR="$TMPCACHE" ./dashboard.sh 2>/dev/null | ansi_to_html)

  cat > "$OUT/$theme.html" <<HTML
<!DOCTYPE html>
<html>
<head><style>
  body { background: transparent; margin: 0; padding: 8px; }
  .window { background: $win; border-radius: 10px; overflow: hidden; display: inline-block; box-shadow: $shadow; }
  .titlebar { background: $bar; padding: 8px 12px; display: flex; gap: 6px; align-items: center; }
  .dot { width: 12px; height: 12px; border-radius: 50%; }
  .dot-red { background: $dotr; }
  .dot-yellow { background: $doty; }
  .dot-green { background: $dotg; }
  .content { padding: 14px 18px; font-family: 'JetBrains Mono','Fira Code','SF Mono','Menlo',monospace; font-size: 13px; line-height: 1.6; }
  pre { margin: 0; white-space: pre; }
</style></head>
<body>
  <div class="window">
    <div class="titlebar"><div class="dot dot-red"></div><div class="dot dot-yellow"></div><div class="dot dot-green"></div></div>
    <div class="content"><pre>$body</pre></div>
  </div>
</body>
</html>
HTML
  printf '  %-18s %s\n' "$theme" "$OUT/$theme.html"
}

TMPCACHE=$(mktemp -d)
trap 'find "$TMPCACHE" -type f -delete 2>/dev/null; rmdir "$TMPCACHE" 2>/dev/null' EXIT

targets="${*:-$ALL}"
echo "rendering:"
for th in $targets; do render "$th"; done
echo "done — open the .html files in a browser to capture .png at 2x"
exit 0
