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

CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"

# Themes whose foregrounds are DARK ink meant for a light page.
LIGHT_THEMES=" light solarized-light paper "

DARK_THEMES="terminal-green solarized nord cyberpunk minimal batman iron-man dbz evangelion
ghost-in-shell akira spider-verse blade-runner one-piece ghibli nebula mythos netrunner
rainforest garden terrarium harvest"

ALL="$DARK_THEMES light solarized-light paper"

# Fixed payload. Placeholder identity ONLY — the previous screenshots shipped a real city.
read -r -d '' PAYLOAD <<'JSON'
{"session_id":"demo","cwd":"/","version":"2.1.220",
 "model":{"display_name":"Opus 5"},
 "cost":{"total_cost_usd":12.34,"total_duration_ms":5400000},
 "context_window":{"context_window_size":1000000,
   "current_usage":{"input_tokens":48000,"cache_read_input_tokens":122000}}}
JSON

# ANSI -> HTML. The converter lives in a temp FILE, deliberately.
#
# It was written as `python3 - <<PY ... PY`, which hands the heredoc to python as ITS STDIN —
# so `sys.stdin.read()` returned nothing and every conversion produced an empty string. The
# HTML still looked structurally fine (frame, titlebar, empty <pre>), the PNG still rendered
# and weighed 15KB of window chrome, and the size guard passed. Three themes producing
# byte-identical 15242-byte files was the only visible tell.
#
# The lesson is the guard, not the heredoc: "file exists and is over 5KB" tests that something
# was written, not that it is what was asked for. verify_render below checks CONTENT.
PYCONV=$(mktemp -t ansi2html.XXXXXX.py)
cat > "$PYCONV" <<'PYEOF'
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
    if color: st.append("color:"+color)
    if bold: st.append("font-weight:600")
    if st: out.append('<span style="'+";".join(st)+'">'); open_span=True
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
PYEOF

ansi_to_html() { python3 "$PYCONV"; }

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
  verify_render "$theme" || return 1
  capture_png "$theme"
  printf '  %-18s %s\n' "$theme" "$OUT/$theme.png"
}

# Rasterise the HTML to PNG with headless Chrome.
#
# TIMEOUT IS MANDATORY, NOT DEFENSIVE. Chrome writes the screenshot and then does not exit —
# measured here, it produced a correct 95KB PNG and sat there until killed at 10 minutes. So
# the exit status is meaningless and the file is the only evidence that matters: wrap in
# `timeout`, ignore rc, then verify the PNG actually exists and is non-trivial. Shipping a
# README that references a .png nobody generated is exactly the failure this function exists
# to prevent — the first version of this change did that, and the broken image links were the
# whole reason it got reverted.
capture_png() {
  local theme="$1" prof png
  [ -x "$CHROME" ] || { echo "  ! chrome not found — $theme.png NOT generated" >&2; return 1; }
  prof=$(mktemp -d)
  png="$OUT/$theme.png"
  timeout 45 "$CHROME" --headless=new --disable-gpu --hide-scrollbars \
    --force-device-scale-factor=2 --default-background-color=00000000 \
    --user-data-dir="$prof" --window-size=1180,240 \
    --screenshot="$png" "file://$PWD/$OUT/$theme.html" >/dev/null 2>&1
  find "$prof" -type f -delete 2>/dev/null; rm -rf "$prof" 2>/dev/null
  if [ ! -s "$png" ] || [ "$(wc -c < "$png")" -lt 5000 ]; then
    echo "  ! $theme.png missing or suspiciously small — NOT usable" >&2
    return 1
  fi
  return 0
}

# Verify the RENDER, not the file. A size check only proves bytes were written: an empty
# dashboard inside a correctly-drawn window frame is a 15KB PNG and a structurally valid HTML
# document, and that is exactly what shipped. Assert on content that can only be present if
# the dashboard actually ran, and on the images differing from each other.
FAILED=0
verify_render() {
  local theme="$1" html="$OUT/$theme.html" body
  body=$(python3 - "$html" <<'PYEOF'
import re, sys
t = open(sys.argv[1], encoding="utf-8", errors="replace").read()
m = re.search(r"<pre>(.*?)</pre>", t, re.S)
inner = re.sub(r"<[^>]+>", "", m.group(1)) if m else ""
sys.stdout.write(inner.strip())
PYEOF
)
  if [ ${#body} -lt 80 ]; then
    echo "  ! $theme: rendered body is ${#body} chars — the dashboard produced nothing" >&2
    FAILED=1; return 1
  fi
  case "$body" in
    *DASHBOARD*|*Cost:*|*Context:*) : ;;
    *) echo "  ! $theme: body has no recognisable dashboard content" >&2; FAILED=1; return 1 ;;
  esac
  return 0
}

TMPCACHE=$(mktemp -d)

# PRE-SEED THE CACHE WITH PLACEHOLDERS. Pointing DASHBOARD_CACHE_DIR at an empty temp dir is
# NOT enough and the first version of this script was wrong to claim it was: an empty cache is
# a COLD cache, every TTL is expired, so the script dutifully fetched live — hitting ipinfo.io
# and the keychain, and baking the real account name and city into the images. That is how the
# existing dark screenshots came to ship a real city in 19 files.
#
# Seeding them fresh means every TTL check passes, nothing is fetched, and the output is
# deterministic. The only way to be sure a screenshot contains no real data is for the script
# to have had no way to obtain any.
cat > "$TMPCACHE/account.json"  <<'J'
{"email":"user@example.com","subscription":"max"}
J
cat > "$TMPCACHE/location.json" <<'J'
{"city":"Springfield","region":"Anystate","country":"US","loc":"0,0"}
J
cat > "$TMPCACHE/weather.json"  <<'J'
{"current":{"temperature_2m":21.0,"weather_code":0}}
J
# Reset timestamps are relative to generation time. Fixed far-future dates rendered the
# countdown as "26450d20h", which is technically correct and obviously nonsense in a
# screenshot. cwd is "/" because df on a non-existent path yields "Disk: ?".
R5H=$(date -u -v+3H +%Y-%m-%dT%H:%M:%S+00:00 2>/dev/null || date -u -d "+3 hours" +%Y-%m-%dT%H:%M:%S+00:00)
R7D=$(date -u -v+4d +%Y-%m-%dT%H:%M:%S+00:00 2>/dev/null || date -u -d "+4 days" +%Y-%m-%dT%H:%M:%S+00:00)
cat > "$TMPCACHE/usage.json" <<J
{"five_hour":{"utilization":34.0,"resets_at":"$R5H"},
 "seven_day":{"utilization":62.0,"resets_at":"$R7D"}}
J
trap 'find "$TMPCACHE" -type f -delete 2>/dev/null; rmdir "$TMPCACHE" 2>/dev/null' EXIT

targets="${*:-$ALL}"
echo "rendering:"
for th in $targets; do render "$th"; done
# Byte-identical PNGs across different themes means nothing themed actually rendered — the
# tell that caught the empty-body bug. Cheap, and it fails loudly rather than shipping.
sums=$(for th in $targets; do [ -f "$OUT/$th.png" ] && shasum -a 256 "$OUT/$th.png" | cut -d" " -f1; done | sort -u | wc -l)
count=$(for th in $targets; do [ -f "$OUT/$th.png" ] && echo x; done | wc -l)
if [ "$count" -gt 1 ] && [ "$sums" -lt "$count" ]; then
  echo "! $count PNGs but only $sums distinct — identical images mean nothing rendered" >&2
  FAILED=1
fi

if [ "$FAILED" -ne 0 ]; then
  echo "FAILED — screenshots are not usable; do not commit them" >&2
  exit 1
fi
echo "done — $count screenshot(s), all verified non-empty and distinct"
exit 0
