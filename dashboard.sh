#!/usr/bin/env bash
# ============================================================================
#  Claude Code Dashboard
#  A beautiful, themeable status line for Claude Code
#
#  Usage:
#    Configure in Claude Code settings.json:
#    "statusLine": { "type": "command", "command": "/path/to/dashboard.sh" }
#
#    Theme selection (set DASHBOARD_THEME env var or pass --theme):
#    DASHBOARD_THEME=cyberpunk /path/to/dashboard.sh
#    /path/to/dashboard.sh --theme nord
#
#  Available themes:
#    terminal-green, solarized, nord, cyberpunk, minimal,
#    batman, iron-man, dbz, evangelion, ghost-in-shell, akira,
#    spider-verse, blade-runner, one-piece, ghibli,
#    nebula, mythos, netrunner
#
#  LIGHT themes (dark ink for a white/cream terminal):
#    light, solarized-light, paper
# ============================================================================

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESET='\033[0m'
BOLD='\033[1m'

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────

CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS_FILE="$CONFIG_DIR/settings.json"
USAGE_CACHE="${DASHBOARD_CACHE_DIR:-$CONFIG_DIR/dashboard-cache}/usage.json"
LOCATION_CACHE="${DASHBOARD_CACHE_DIR:-$CONFIG_DIR/dashboard-cache}/location.json"
WEATHER_CACHE="${DASHBOARD_CACHE_DIR:-$CONFIG_DIR/dashboard-cache}/weather.json"
ACCOUNT_CACHE="${DASHBOARD_CACHE_DIR:-$CONFIG_DIR/dashboard-cache}/account.json"

USAGE_CACHE_TTL=${DASHBOARD_USAGE_TTL:-60}         # 60s — sync with the statusline refresh
LOCATION_CACHE_TTL=${DASHBOARD_LOCATION_TTL:-3600} # 1 hour
WEATHER_CACHE_TTL=${DASHBOARD_WEATHER_TTL:-900}    # 15 minutes
ACCOUNT_CACHE_TTL=${DASHBOARD_ACCOUNT_TTL:-60}     # 60s — sync with dashboard refresh

# Context baseline: preloaded tokens not visible to hooks
# API usage fields (cache_read + cache_creation + input_tokens) already
# include the full system prompt, so no baseline adjustment is needed.
CONTEXT_BASELINE=${DASHBOARD_CONTEXT_BASELINE:-0}

# Theme (env var > CLI arg > config file > default)
THEME="${DASHBOARD_THEME:-harvest}"

# Parse CLI args
for arg in "$@"; do
  case "$arg" in
    --theme=*) THEME="${arg#*=}" ;;
    --theme) shift_next=1 ;;
    *)
      if [ "$shift_next" = "1" ]; then
        THEME="$arg"
        shift_next=0
      fi
      ;;
  esac
done

# Source .env for API keys (weather, etc.)
[ -f "$CONFIG_DIR/.env" ] && source "$CONFIG_DIR/.env"

mkdir -p "$(dirname "$USAGE_CACHE")" 2>/dev/null

# ─────────────────────────────────────────────────────────────────────────────
# SHARED HELPERS
# ─────────────────────────────────────────────────────────────────────────────

# ONE clock for the whole render. `date +%s` was called at six separate sites, which forks
# six times and — worse — lets different sections of a single panel compute ages against
# different "now"s. A render is a snapshot; it should have one timestamp.
NOW=$(date +%s)

# Integer predicate. Used for every value that reaches $(( )) or `[ -n ] -gt`, because
# "non-empty" is not "numeric": a multi-line string, an error message on stdout, "80x24"
# and "-1" are all non-empty and none is a width.
is_pos_int() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# Age of a file in seconds, or the sentinel 999999 when it does not exist / cannot be read.
#
# NEGATIVE AGES ARE THE BUG THIS EXISTS FOR. Every site computed `NOW - mtime` unguarded. If
# mtime is ever in the FUTURE — clock corrected backwards, a file restored with `cp -p`, a
# synced or NFS volume with a skewed writer — the age goes negative, `age -gt TTL` is false
# forever, and the cache NEVER refreshes again. That is the same skew-toward-fresh failure as
# a stale-heartbeat check reading a future timestamp as live: the direction of the error
# disables the very refresh that would correct it, and nothing reports a fault because the
# panel keeps rendering the last good values indefinitely.
file_age() {
  [ -f "$1" ] || { printf '%s\n' 999999; return; }
  local m age
  m=$(stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null) || m=""
  is_pos_int "$m" || { printf '%s\n' 999999; return; }
  age=$(( NOW - m ))
  [ "$age" -ge 0 ] || age=999999          # future mtime -> treat as stale, never as fresh
  printf '%s\n' "$age"
}

# Write a cache file atomically: temp in the SAME directory, then rename.
# `echo "$data" > "$CACHE"` truncates first, so a concurrent reader — a second instance when
# a run overruns the 60s tick — can observe an empty or half-written file and every jq against
# it fails for the rest of the TTL. rename(2) is atomic, so a reader sees old or new, never a
# torn middle. Callers still validate the payload parses BEFORE calling this.
cache_write() {
  local dest="$1" data="$2" tmp
  tmp=$(mktemp "${dest}.XXXXXX" 2>/dev/null) || return 1
  if printf '%s\n' "$data" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$dest" 2>/dev/null && return 0
  fi
  rm -f "$tmp" 2>/dev/null
  return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# TERMINAL WIDTH DETECTION
# ─────────────────────────────────────────────────────────────────────────────

detect_terminal_width() {
  # VALIDATE SHAPE, NOT EMPTINESS. This was a chain of
  #     [ -z "$w" ] || [ "$w" = "0" ] && w=<next source>
  # which parses as `(A || B) && C` and is accidentally correct for empty/"0"/valid — but the
  # PREDICATE is wrong. "Non-empty and not exactly 0" admits multi-line output ("80\n24"), an
  # error string printed to stdout, "80x24", "-1", "00". Every one of those was accepted as a
  # width and reached `$(( width - 4 ))`. The first source is a terminal query running in a
  # process with NO CONTROLLING TERMINAL, so those malformed outputs are its LIKELY results,
  # not exotic ones. is_pos_int tests the property that actually matters.
  #
  # The chain was also ordered worst-first. Headless — which is how this runs — kitty's query
  # and stty-on-/dev/tty cannot work, `tput` needs a TERM that is usually unset, and bash only
  # sets COLUMNS in interactive shells, so `${COLUMNS:-80}` was effectively always the literal
  # 80. Honest ordering puts the caller-supplied width first and treats 80 as the default it
  # has always actually been.
  local w
  for w in "$DASHBOARD_WIDTH" \
           "$(kitty_width)" \
           "$(stty_width)" \
           "$(tput cols 2>/dev/null)" \
           "$COLUMNS" \
           80; do
    if is_pos_int "$w" && [ "$w" -ge 20 ]; then printf '%s\n' "$w"; return 0; fi
  done
  printf '%s\n' 80
}

kitty_width() {
  [ -n "$KITTY_WINDOW_ID" ] && command -v kitten >/dev/null 2>&1 || return 0
  kitten @ ls 2>/dev/null | jq -r --argjson wid "$KITTY_WINDOW_ID" \
    '[.[] | .tabs[] | .windows[] | select(.id == $wid)] | .[0].columns // empty' 2>/dev/null
}

stty_width() {
  # REDIRECTION ORDER IS THE FIX. This was `stty size </dev/tty 2>/dev/null`: bash applies
  # redirections left to right, so the INPUT redirect fails before stderr has been silenced
  # and the shell's own complaint — "line 80: /dev/tty: Device not configured" — escapes to
  # the real stderr on every run. At a 60s cadence that is ~1400 lines/day into whatever the
  # parent does with stderr, and if the parent ever merges stderr into stdout it lands inside
  # the rendered panel. Test readability first and skip entirely when there is no tty.
  [ -r /dev/tty ] || return 0
  stty size 2>/dev/null </dev/tty | awk '{print $2}'
}

TERM_WIDTH=$(detect_terminal_width)

if [ "$TERM_WIDTH" -lt 40 ]; then
  MODE="compact"
elif [ "$TERM_WIDTH" -lt 80 ]; then
  MODE="standard"
else
  MODE="full"
fi

# ─────────────────────────────────────────────────────────────────────────────
# PARSE INPUT (JSON from Claude Code via stdin)
# ─────────────────────────────────────────────────────────────────────────────

input=$(cat)
# STDIN IS CONSUMED EXACTLY ONCE, THEN CLOSED. The parent pipes a JSON blob here; any child
# that reads stdin — an unredirected command, a `read` loop, curl with a stdin option — would
# eat part of it, and the symptom is a field that is empty only sometimes, which is close to
# undiagnosable. Point it at /dev/null so no descendant can touch it.
exec </dev/null

# DEGRADED MODE. With errexit deliberately off (a renderer's contract is "always emit a line",
# so aborting halfway is worse than a panel with one blank field), a missing `jq` makes EVERY
# field empty and the panel renders as a plausible-looking box full of blanks — total silent
# degradation that looks like "no data yet". Headless launchers routinely provide a minimal
# PATH without /opt/homebrew/bin, so this is the normal failure, not an exotic one. Say so.
DEGRADED=""
command -v jq   >/dev/null 2>&1 || DEGRADED="jq missing"
command -v curl >/dev/null 2>&1 || DEGRADED="${DEGRADED:+$DEGRADED, }curl missing"
if [ -n "$DEGRADED" ]; then
  printf 'dashboard: DEGRADED — %s (PATH=%s)\n' "$DEGRADED" "$PATH"
  exit 0
fi

# EVERY value is @sh-quoted before it reaches eval. THIS IS LOAD-BEARING, NOT STYLE.
#
# The numeric fields below used `| tostring` while only the four string fields used `@sh`.
# JSON does not constrain a field's type to what we expect, so a STRING in any "numeric"
# slot was interpolated raw into the text handed to `eval` — i.e. arbitrary command
# execution from the payload on stdin. Demonstrated against this script:
#
#     {"context_window":{"used_percentage":"0; touch /tmp/proof; #"}}   ->  file created
#
# `tostring` converts a value to a string; it does NOT make it safe to eval. `@sh` is the
# operator that shell-quotes, and it is correct on numbers too, so there is no reason for
# any field here to skip it. Fields are consumed as strings and validated numerically at
# point of use — see is_pos_int — because a shell-quoted non-number is still a non-number.
eval "$(echo "$input" | jq -r '
  "current_dir=" + (.workspace.current_dir // .cwd // "" | @sh) + "\n" +
  "transcript_path=" + (.transcript_path // "" | @sh) + "\n" +
  "model_name=" + (.model.display_name // "unknown" | @sh) + "\n" +
  "cc_version=" + (.version // "" | @sh) + "\n" +
  "duration_ms=" + (.cost.total_duration_ms // 0 | tostring | @sh) + "\n" +
  "cache_read=" + ((.context_window.current_usage.cache_read_input_tokens // 0) | tostring | @sh) + "\n" +
  "input_tokens=" + ((.context_window.current_usage.input_tokens // 0) | tostring | @sh) + "\n" +
  "cache_creation=" + ((.context_window.current_usage.cache_creation_input_tokens // 0) | tostring | @sh) + "\n" +
  "output_tokens=" + ((.context_window.current_usage.output_tokens // 0) | tostring | @sh) + "\n" +
  "context_max=" + (.context_window.context_window_size // 0 | tostring | @sh) + "\n" +
  "context_used_pct=" + (.context_window.used_percentage // "" | tostring | @sh) + "\n" +
  "rl_5h_pct=" + (.rate_limits.five_hour.used_percentage // "" | tostring | @sh) + "\n" +
  "rl_5h_reset=" + (.rate_limits.five_hour.resets_at // "" | tostring | @sh) + "\n" +
  "rl_7d_pct=" + (.rate_limits.seven_day.used_percentage // "" | tostring | @sh) + "\n" +
  "rl_7d_reset=" + (.rate_limits.seven_day.resets_at // "" | tostring | @sh)
' 2>/dev/null)"

# Numeric fields reaching $(( )) must be integers. bash arithmetic evaluates array
# subscripts, and a subscript can contain a command substitution — `x="a[$(cmd)]"` inside
# $(( x + 0 )) EXECUTES cmd (verified on this box). @sh above stops the eval injection;
# this stops the arithmetic one, which is a separate context with its own rules.
for _n in duration_ms cache_read input_tokens cache_creation output_tokens context_max; do
  is_pos_int "${!_n}" || printf -v "$_n" '%s' 0
done
unset _n

# Defaults for empty values
cache_read=${cache_read:-0}
input_tokens=${input_tokens:-0}
cache_creation=${cache_creation:-0}
output_tokens=${output_tokens:-0}
context_max=${context_max:-0}
duration_ms=${duration_ms:-0}
cc_version=${cc_version:-$(claude --version 2>/dev/null | head -1 | awk '{print $1}')}
cc_version=${cc_version:-unknown}

# ─────────────────────────────────────────────────────────────────────────────
# THEME DEFINITIONS
# ─────────────────────────────────────────────────────────────────────────────

load_theme() {
  local theme="$1"
  case "$theme" in

    terminal-green)
      T_HEADER="DASHBOARD"
      T_BORDER='\033[38;2;0;60;0m'
      T_TITLE='\033[1;38;2;0;200;0m'
      T_LABEL='\033[38;2;0;120;0m'
      T_VALUE='\033[38;2;0;160;0m'
      T_HIGHLIGHT='\033[1;38;2;0;200;0m'
      T_ACCENT1='\033[38;2;0;120;0m'
      T_ACCENT2='\033[38;2;0;120;0m'
      T_ACCENT3='\033[38;2;0;120;0m'
      T_ACCENT4='\033[38;2;0;120;0m'
      T_GREEN='\033[1;38;2;0;200;0m'
      T_YELLOW='\033[38;2;0;180;0m'
      T_RED='\033[1;38;2;0;255;0m'
      T_DIM='\033[38;2;0;40;0m'
      T_WEATHER='\033[38;2;0;140;0m'
      T_BAR_SESSION='\033[1;38;2;0;255;0m'
      T_BAR_WEEK='\033[38;2;0;180;0m'
      T_BAR_CTX='\033[38;2;0;120;0m'
      T_SEP="│"
      T_LINE_H="─"
      T_LINE_TOP="─"
      T_BAR_FILL="#"
      T_BAR_EMPTY="."
      T_ICON_CTX=""
      T_ICON_USE=""
      T_ICON_SES=""
      T_ICON_TIME=""
      ;;

    solarized)
      T_HEADER="DASHBOARD"
      T_BORDER='\033[38;2;88;110;117m'
      T_TITLE='\033[38;2;38;139;210m'
      T_LABEL='\033[38;2;101;123;131m'
      T_VALUE='\033[38;2;147;161;161m'
      T_HIGHLIGHT='\033[38;2;147;161;161m'
      T_ACCENT1='\033[38;2;181;137;0m'    # yellow
      T_ACCENT2='\033[38;2;181;137;0m'
      T_ACCENT3='\033[38;2;108;113;196m'  # violet
      T_ACCENT4='\033[38;2;108;113;196m'
      T_GREEN='\033[38;2;133;153;0m'
      T_YELLOW='\033[38;2;181;137;0m'
      T_RED='\033[38;2;220;50;47m'
      T_DIM='\033[38;2;7;54;66m'
      T_WEATHER='\033[38;2;42;161;152m'
      T_BAR_SESSION='\033[38;2;220;50;47m'
      T_BAR_WEEK='\033[38;2;181;137;0m'
      T_BAR_CTX='\033[38;2;108;113;196m'
      T_SEP="│"
      T_LINE_H="─"
      T_LINE_TOP="━"
      T_BAR_FILL="█"
      T_BAR_EMPTY="█"
      T_ICON_CTX="◉"
      T_ICON_USE="⚡"
      T_ICON_SES="⬡"
      T_ICON_TIME="⏱"
      ;;

    nord)
      T_HEADER="DASHBOARD"
      T_BORDER='\033[38;2;59;66;82m'
      T_TITLE='\033[38;2;136;192;208m'
      T_LABEL='\033[38;2;76;86;106m'
      T_VALUE='\033[38;2;216;222;233m'
      T_HIGHLIGHT='\033[38;2;229;233;240m'
      T_ACCENT1='\033[38;2;235;203;139m'  # aurora yellow
      T_ACCENT2='\033[38;2;235;203;139m'
      T_ACCENT3='\033[38;2;180;142;173m'  # aurora purple
      T_ACCENT4='\033[38;2;129;161;193m'  # frost blue
      T_GREEN='\033[38;2;163;190;140m'
      T_YELLOW='\033[38;2;235;203;139m'
      T_RED='\033[38;2;191;97;106m'
      T_DIM='\033[38;2;46;52;64m'
      T_WEATHER='\033[38;2;163;190;140m'
      T_BAR_SESSION='\033[38;2;191;97;106m'
      T_BAR_WEEK='\033[38;2;235;203;139m'
      T_BAR_CTX='\033[38;2;180;142;173m'
      T_SEP="│"
      T_LINE_H="─"
      T_LINE_TOP="━"
      T_BAR_FILL="█"
      T_BAR_EMPTY="█"
      T_ICON_CTX="◉"
      T_ICON_USE="⚡"
      T_ICON_SES="⬡"
      T_ICON_TIME="⏱"
      ;;

    cyberpunk)
      # 5 NEON COLORS:
      #   1. Hot Pink  255;45;149  — headers, high-priority labels
      #   2. Neon Red  255;30;30   — location, weather, highlights
      #   3. Acid Green 57;255;20  — data values (model, turns, cost, duration)
      #   4. Neon Orange 255;107;43 — usage, percentages, system stats
      #   5. Electric Cyan 0;240;255 — context, session, time
      T_HEADER="DASHBOARD"
      T_BORDER='\033[38;2;60;0;80m'
      T_TITLE='\033[1;38;2;255;45;149m'        # 1 hot pink
      T_LABEL='\033[1;38;2;255;45;149m'         # 1 hot pink - all labels
      T_VALUE='\033[1;38;2;57;255;20m'         # 3 acid green - all values
      T_HIGHLIGHT='\033[1;38;2;255;30;30m'     # 2 neon red - city, weather
      T_ACCENT1='\033[1;38;2;255;45;149m'      # 1 hot pink - Model:/Skills:/MCP:
      T_ACCENT2='\033[1;38;2;255;107;43m'      # 4 neon orange - usage icon + label only
      T_ACCENT3='\033[1;38;2;0;240;255m'       # 5 electric cyan - session section
      T_ACCENT4='\033[1;38;2;0;240;255m'       # 5 electric cyan - context section
      T_GREEN='\033[1;38;2;57;255;20m'         # 3 acid green - low usage
      T_YELLOW='\033[1;38;2;255;107;43m'       # 4 neon orange - medium usage
      T_RED='\033[1;38;2;255;30;30m'           # 2 neon red - high usage
      T_DIM='\033[38;2;40;0;55m'
      T_WEATHER='\033[1;38;2;255;30;30m'       # 2 neon red - weather
      T_BAR_SESSION='\033[1;38;2;255;30;30m'
      T_BAR_WEEK='\033[1;38;2;255;107;43m'
      T_BAR_CTX='\033[1;38;2;150;0;255m'
      T_SEP="║"
      T_LINE_H="═"
      T_LINE_TOP="═"
      T_BAR_FILL="▓"
      T_BAR_EMPTY="░"
      T_ICON_CTX="◉"
      T_ICON_USE="⚡"
      T_ICON_SES="⬡"
      T_ICON_TIME="⏱"
      ;;

    minimal)
      T_HEADER="DASHBOARD"
      T_BORDER='\033[90m'
      T_TITLE='\033[1;37m'
      T_LABEL='\033[90m'
      T_VALUE='\033[37m'
      T_HIGHLIGHT='\033[37m'
      T_ACCENT1='\033[90m'
      T_ACCENT2='\033[90m'
      T_ACCENT3='\033[90m'
      T_ACCENT4='\033[90m'
      T_GREEN='\033[32m'
      T_YELLOW='\033[33m'
      T_RED='\033[31m'
      T_DIM='\033[90m'
      T_WEATHER='\033[90m'
      T_BAR_SESSION='\033[31m'
      T_BAR_WEEK='\033[33m'
      T_BAR_CTX='\033[34m'
      T_SEP=" "
      T_LINE_H="·"
      T_LINE_TOP=""
      T_BAR_FILL="█"
      T_BAR_EMPTY="░"
      T_ICON_CTX=""
      T_ICON_USE=""
      T_ICON_SES=""
      T_ICON_TIME=""
      ;;

    # ── LIGHT THEMES ─────────────────────────────────────────────────────────
    # Every other theme in this file is FOREGROUND-ONLY and assumes a dark terminal:
    # they lean on bright white (37), bright black (90) and neon truecolor, all of
    # which are somewhere between low-contrast and invisible on a light background.
    # These three are built the other way round — dark ink for a light page — so they
    # are the ones to pick if your terminal background is white/cream rather than
    # near-black. Contrast ratios below are against the noted background.

    light)
      # Neutral, high-contrast. Ink on white (#ffffff): body text ~12:1, labels ~5.7:1.
      T_HEADER="DASHBOARD"
      T_BORDER='\033[38;2;154;160;166m'      # #9aa0a6 grey rule
      T_TITLE='\033[1;38;2;32;33;36m'        # #202124 near-black
      T_LABEL='\033[38;2;95;99;104m'         # #5f6368 secondary
      T_VALUE='\033[38;2;32;33;36m'          # #202124 primary
      T_HIGHLIGHT='\033[38;2;24;90;188m'     # #185abc blue
      T_ACCENT1='\033[38;2;154;52;18m'       # #9a3412 rust
      T_ACCENT2='\033[38;2;21;101;93m'       # #15655d teal
      T_ACCENT3='\033[38;2;91;33;182m'       # #5b21b6 violet
      T_ACCENT4='\033[38;2;95;99;104m'
      T_GREEN='\033[38;2;20;108;67m'         # #146c43
      T_YELLOW='\033[38;2;146;100;0m'        # #926400 — dark enough to read on white
      T_RED='\033[38;2;176;0;32m'            # #b00020
      T_DIM='\033[38;2;128;134;139m'
      T_WEATHER='\033[38;2;24;90;188m'
      T_BAR_SESSION='\033[38;2;176;0;32m'
      T_BAR_WEEK='\033[38;2;146;100;0m'
      T_BAR_CTX='\033[38;2;24;90;188m'
      T_SEP="│"
      T_LINE_H="─"
      T_LINE_TOP=""
      T_BAR_FILL="█"
      T_BAR_EMPTY="░"
      T_ICON_CTX="◆"
      T_ICON_USE="▲"
      T_ICON_SES="●"
      T_ICON_TIME="◷"
      ;;

    solarized-light)
      # Ethan Schoonover's light palette on base3 (#fdf6e3). base00 body ~7.5:1.
      T_HEADER="DASHBOARD"
      T_BORDER='\033[38;2;147;161;161m'      # base1
      T_TITLE='\033[1;38;2;7;54;66m'         # base02
      T_LABEL='\033[38;2;88;110;117m'        # base01
      T_VALUE='\033[38;2;88;110;117m'        # base01 — base00 measures 4.45:1 on white, just under the 4.5 body bar
      T_HIGHLIGHT='\033[38;2;38;139;210m'    # blue
      T_ACCENT1='\033[38;2;203;75;22m'       # orange
      T_ACCENT2='\033[38;2;42;161;152m'      # cyan
      T_ACCENT3='\033[38;2;108;113;196m'     # violet
      T_ACCENT4='\033[38;2;88;110;117m'
      T_GREEN='\033[38;2;133;153;0m'
      T_YELLOW='\033[38;2;181;137;0m'
      T_RED='\033[38;2;220;50;47m'
      T_DIM='\033[38;2;147;161;161m'
      T_WEATHER='\033[38;2;38;139;210m'
      T_BAR_SESSION='\033[38;2;220;50;47m'
      T_BAR_WEEK='\033[38;2;181;137;0m'
      T_BAR_CTX='\033[38;2;38;139;210m'
      T_SEP="│"
      T_LINE_H="─"
      T_LINE_TOP=""
      T_BAR_FILL="█"
      T_BAR_EMPTY="░"
      T_ICON_CTX="◆"
      T_ICON_USE="▲"
      T_ICON_SES="●"
      T_ICON_TIME="◷"
      ;;

    paper)
      # Warm, low-chroma, for cream backgrounds (#faf4ed). Deliberately quiet: one
      # accent hue, no emoji-weight icons, so the numbers carry the emphasis.
      T_HEADER="DASHBOARD"
      T_BORDER='\033[38;2;180;170;158m'
      T_TITLE='\033[1;38;2;87;82;121m'       # #575279 iris
      T_LABEL='\033[38;2;121;117;147m'
      T_VALUE='\033[38;2;87;82;121m'
      T_HIGHLIGHT='\033[38;2;40;105;131m'    # pine
      T_ACCENT1='\033[38;2;180;99;122m'      # rose
      T_ACCENT2='\033[38;2;86;148;159m'      # foam
      T_ACCENT3='\033[38;2;144;122;169m'
      T_ACCENT4='\033[38;2;121;117;147m'
      T_GREEN='\033[38;2;40;105;131m'
      T_YELLOW='\033[38;2;176;115;15m'       # #b0730f — the original #ea9d34 is 2.2:1 on white
      T_RED='\033[38;2;180;99;122m'
      T_DIM='\033[38;2;152;147;165m'
      T_WEATHER='\033[38;2;86;148;159m'
      T_BAR_SESSION='\033[38;2;180;99;122m'
      T_BAR_WEEK='\033[38;2;176;115;15m'
      T_BAR_CTX='\033[38;2;40;105;131m'
      T_SEP="·"
      T_LINE_H="─"
      T_LINE_TOP=""
      T_BAR_FILL="▓"
      T_BAR_EMPTY="░"
      T_ICON_CTX=""
      T_ICON_USE=""
      T_ICON_SES=""
      T_ICON_TIME=""
      ;;

    batman)
      T_HEADER="BATCOMPUTER"
      T_BORDER='\033[38;2;16;21;46m'
      T_TITLE='\033[1;38;2;245;197;24m'
      T_LABEL='\033[38;2;80;80;100m'
      T_VALUE='\033[38;2;180;180;195m'
      T_HIGHLIGHT='\033[1;38;2;245;197;24m'
      T_ACCENT1='\033[38;2;245;197;24m'   # bat yellow
      T_ACCENT2='\033[38;2;245;197;24m'
      T_ACCENT3='\033[38;2;60;60;90m'     # dark blue
      T_ACCENT4='\033[38;2;100;100;130m'
      T_GREEN='\033[38;2;245;197;24m'
      T_YELLOW='\033[38;2;245;197;24m'
      T_RED='\033[38;2;180;40;40m'
      T_DIM='\033[38;2;26;26;46m'
      T_WEATHER='\033[38;2;100;100;140m'
      T_BAR_SESSION='\033[38;2;180;40;40m'
      T_BAR_WEEK='\033[38;2;245;197;24m'
      T_BAR_CTX='\033[38;2;60;60;120m'
      T_SEP="│"
      T_LINE_H="─"
      T_LINE_TOP="━"
      T_BAR_FILL="█"
      T_BAR_EMPTY="░"
      T_ICON_CTX="🦇"
      T_ICON_USE="⚡"
      T_ICON_SES="◆"
      T_ICON_TIME="⏱"
      ;;

    iron-man)
      T_HEADER="J.A.R.V.I.S."
      T_BORDER='\033[38;2;30;30;50m'
      T_TITLE='\033[1;38;2;0;180;216m'
      T_LABEL='\033[38;2;100;100;120m'
      T_VALUE='\033[38;2;200;200;210m'
      T_HIGHLIGHT='\033[1;38;2;255;215;0m'
      T_ACCENT1='\033[38;2;0;180;216m'    # arc reactor blue
      T_ACCENT2='\033[38;2;255;215;0m'    # gold
      T_ACCENT3='\033[38;2;220;20;60m'    # red
      T_ACCENT4='\033[38;2;0;180;216m'
      T_GREEN='\033[38;2;0;180;216m'
      T_YELLOW='\033[38;2;255;215;0m'
      T_RED='\033[38;2;220;20;60m'
      T_DIM='\033[38;2;25;25;40m'
      T_WEATHER='\033[38;2;0;150;190m'
      T_BAR_SESSION='\033[38;2;220;20;60m'
      T_BAR_WEEK='\033[38;2;255;215;0m'
      T_BAR_CTX='\033[38;2;0;180;216m'
      T_SEP="│"
      T_LINE_H="─"
      T_LINE_TOP="═"
      T_BAR_FILL="█"
      T_BAR_EMPTY="░"
      T_ICON_CTX="⊕"
      T_ICON_USE="⚡"
      T_ICON_SES="◈"
      T_ICON_TIME="⏱"
      ;;

    dbz)
      T_HEADER=">>> SCOUTER <<<"
      T_BORDER='\033[38;2;40;20;0m'
      T_TITLE='\033[1;38;2;255;107;0m'
      T_LABEL='\033[38;2;150;100;30m'
      T_VALUE='\033[38;2;255;215;0m'
      T_HIGHLIGHT='\033[1;38;2;255;107;0m'
      T_ACCENT1='\033[38;2;255;107;0m'    # orange
      T_ACCENT2='\033[38;2;255;215;0m'    # yellow
      T_ACCENT3='\033[38;2;255;50;50m'    # red ki
      T_ACCENT4='\033[38;2;0;150;255m'    # blue ki
      T_GREEN='\033[38;2;255;215;0m'
      T_YELLOW='\033[38;2;255;107;0m'
      T_RED='\033[38;2;255;50;50m'
      T_DIM='\033[38;2;40;25;5m'
      T_WEATHER='\033[38;2;200;150;50m'
      T_BAR_SESSION='\033[38;2;255;50;50m'
      T_BAR_WEEK='\033[38;2;255;107;0m'
      T_BAR_CTX='\033[38;2;0;150;255m'
      T_SEP="│"
      T_LINE_H="─"
      T_LINE_TOP="━"
      T_BAR_FILL="◆"
      T_BAR_EMPTY="◇"
      T_ICON_CTX="◆"
      T_ICON_USE="⚡"
      T_ICON_SES="◈"
      T_ICON_TIME="⏱"
      ;;

    evangelion)
      T_HEADER="NERV MAGI SYSTEM"
      T_BORDER='\033[38;2;20;40;0m'
      T_TITLE='\033[1;38;2;204;0;0m'
      T_LABEL='\033[38;2;100;130;50m'
      T_VALUE='\033[38;2;255;140;0m'
      T_HIGHLIGHT='\033[1;38;2;204;0;0m'
      T_ACCENT1='\033[38;2;204;0;0m'      # NERV red
      T_ACCENT2='\033[38;2;255;140;0m'    # amber
      T_ACCENT3='\033[38;2;80;130;40m'    # green
      T_ACCENT4='\033[38;2;150;0;150m'    # purple
      T_GREEN='\033[38;2;80;180;40m'
      T_YELLOW='\033[38;2;255;140;0m'
      T_RED='\033[1;38;2;204;0;0m'
      T_DIM='\033[38;2;15;30;0m'
      T_WEATHER='\033[38;2;100;140;60m'
      T_BAR_SESSION='\033[1;38;2;204;0;0m'
      T_BAR_WEEK='\033[38;2;255;140;0m'
      T_BAR_CTX='\033[38;2;150;0;150m'
      T_SEP="│"
      T_LINE_H="─"
      T_LINE_TOP="━"
      T_BAR_FILL="█"
      T_BAR_EMPTY="░"
      T_ICON_CTX="⬡"
      T_ICON_USE="⚠"
      T_ICON_SES="◉"
      T_ICON_TIME="⏱"
      ;;

    ghost-in-shell)
      T_HEADER="SECTION 9"
      T_BORDER='\033[38;2;10;14;26m'
      T_TITLE='\033[1;38;2;0;255;204m'
      T_LABEL='\033[38;2;50;70;100m'
      T_VALUE='\033[38;2;0;200;170m'
      T_HIGHLIGHT='\033[1;38;2;0;255;204m'
      T_ACCENT1='\033[38;2;0;255;204m'    # cyan
      T_ACCENT2='\033[38;2;0;180;150m'
      T_ACCENT3='\033[38;2;80;100;160m'   # blue-gray
      T_ACCENT4='\033[38;2;0;200;170m'
      T_GREEN='\033[38;2;0;255;204m'
      T_YELLOW='\033[38;2;0;200;170m'
      T_RED='\033[38;2;255;60;80m'
      T_DIM='\033[38;2;15;20;35m'
      T_WEATHER='\033[38;2;0;150;130m'
      T_BAR_SESSION='\033[38;2;255;60;80m'
      T_BAR_WEEK='\033[38;2;0;200;170m'
      T_BAR_CTX='\033[38;2;80;100;160m'
      T_SEP="▐"
      T_LINE_H="▌"
      T_LINE_TOP="▐"
      T_BAR_FILL="▓"
      T_BAR_EMPTY="░"
      T_ICON_CTX=">>"
      T_ICON_USE=">>"
      T_ICON_SES=">>"
      T_ICON_TIME=">>"
      ;;

    akira)
      T_HEADER="KANEDA ///"
      T_BORDER='\033[38;2;29;53;87m'
      T_TITLE='\033[1;38;2;230;57;70m'
      T_LABEL='\033[38;2;80;100;140m'
      T_VALUE='\033[38;2;230;230;240m'
      T_HIGHLIGHT='\033[1;38;2;230;57;70m'
      T_ACCENT1='\033[38;2;230;57;70m'    # capsule red
      T_ACCENT2='\033[38;2;230;230;240m'  # white
      T_ACCENT3='\033[38;2;29;53;87m'     # dark blue
      T_ACCENT4='\033[38;2;100;130;180m'
      T_GREEN='\033[38;2;100;200;150m'
      T_YELLOW='\033[38;2;230;200;100m'
      T_RED='\033[1;38;2;230;57;70m'
      T_DIM='\033[38;2;20;35;60m'
      T_WEATHER='\033[38;2;100;130;170m'
      T_BAR_SESSION='\033[1;38;2;230;57;70m'
      T_BAR_WEEK='\033[38;2;230;200;100m'
      T_BAR_CTX='\033[38;2;100;130;180m'
      T_SEP="│"
      T_LINE_H="─"
      T_LINE_TOP="═"
      T_BAR_FILL="█"
      T_BAR_EMPTY="░"
      T_ICON_CTX="◉"
      T_ICON_USE="⚡"
      T_ICON_SES="◆"
      T_ICON_TIME="⏱"
      ;;

    spider-verse)
      T_HEADER="SPIDER-VERSE"
      T_BORDER='\033[38;2;20;20;30m'
      T_TITLE='\033[1;38;2;225;29;72m'
      T_LABEL='\033[38;2;80;80;110m'
      T_VALUE='\033[38;2;200;200;220m'
      T_HIGHLIGHT='\033[1;38;2;37;99;235m'
      T_ACCENT1='\033[38;2;225;29;72m'    # red
      T_ACCENT2='\033[38;2;37;99;235m'    # blue
      T_ACCENT3='\033[38;2;255;200;50m'   # yellow pop
      T_ACCENT4='\033[38;2;225;29;72m'
      T_GREEN='\033[38;2;37;99;235m'
      T_YELLOW='\033[38;2;255;200;50m'
      T_RED='\033[1;38;2;225;29;72m'
      T_DIM='\033[38;2;25;25;35m'
      T_WEATHER='\033[38;2;100;100;150m'
      T_BAR_SESSION='\033[1;38;2;225;29;72m'
      T_BAR_WEEK='\033[38;2;255;200;50m'
      T_BAR_CTX='\033[38;2;37;99;235m'
      T_SEP="│"
      T_LINE_H="╌"
      T_LINE_TOP="━"
      T_BAR_FILL="●"
      T_BAR_EMPTY="○"
      T_ICON_CTX="◉"
      T_ICON_USE="⚡"
      T_ICON_SES="◆"
      T_ICON_TIME="⏱"
      ;;

    blade-runner)
      T_HEADER="VOIGHT-KAMPFF"
      T_BORDER='\033[38;2;40;40;45m'
      T_TITLE='\033[1;38;2;255;69;0m'
      T_LABEL='\033[38;2;90;90;100m'
      T_VALUE='\033[38;2;180;180;190m'
      T_HIGHLIGHT='\033[38;2;0;139;139m'
      T_ACCENT1='\033[38;2;255;69;0m'     # orange neon
      T_ACCENT2='\033[38;2;0;139;139m'    # teal
      T_ACCENT3='\033[38;2;255;105;180m'  # pink
      T_ACCENT4='\033[38;2;100;100;110m'
      T_GREEN='\033[38;2;0;139;139m'
      T_YELLOW='\033[38;2;255;69;0m'
      T_RED='\033[38;2;255;105;180m'
      T_DIM='\033[38;2;30;30;35m'
      T_WEATHER='\033[38;2;0;120;120m'
      T_BAR_SESSION='\033[38;2;255;69;0m'
      T_BAR_WEEK='\033[38;2;255;105;180m'
      T_BAR_CTX='\033[38;2;0;139;139m'
      T_SEP="┊"
      T_LINE_H="┄"
      T_LINE_TOP="┄"
      T_BAR_FILL="█"
      T_BAR_EMPTY="░"
      T_ICON_CTX="◉"
      T_ICON_USE="⚡"
      T_ICON_SES="◇"
      T_ICON_TIME="⏱"
      ;;

    one-piece)
      T_HEADER="LOG POSE"
      T_BORDER='\033[38;2;0;60;80m'
      T_TITLE='\033[1;38;2;255;215;0m'
      T_LABEL='\033[38;2;0;105;148m'
      T_VALUE='\033[38;2;240;240;240m'
      T_HIGHLIGHT='\033[1;38;2;255;215;0m'
      T_ACCENT1='\033[38;2;255;215;0m'    # gold
      T_ACCENT2='\033[38;2;220;50;50m'    # red
      T_ACCENT3='\033[38;2;0;105;148m'    # ocean blue
      T_ACCENT4='\033[38;2;255;215;0m'
      T_GREEN='\033[38;2;50;200;100m'
      T_YELLOW='\033[38;2;255;215;0m'
      T_RED='\033[38;2;220;50;50m'
      T_DIM='\033[38;2;0;40;55m'
      T_WEATHER='\033[38;2;100;180;220m'
      T_BAR_SESSION='\033[38;2;220;50;50m'
      T_BAR_WEEK='\033[38;2;255;215;0m'
      T_BAR_CTX='\033[38;2;0;105;148m'
      T_SEP="│"
      T_LINE_H="─"
      T_LINE_TOP="━"
      T_BAR_FILL="█"
      T_BAR_EMPTY="░"
      T_ICON_CTX="⚓"
      T_ICON_USE="⚡"
      T_ICON_SES="☠"
      T_ICON_TIME="⏱"
      ;;

    ghibli)
      T_HEADER="CATBUS"
      T_BORDER='\033[38;2;74;93;59m'
      T_TITLE='\033[38;2;139;115;85m'
      T_LABEL='\033[38;2;100;120;80m'
      T_VALUE='\033[38;2;200;195;180m'
      T_HIGHLIGHT='\033[38;2;255;248;220m'
      T_ACCENT1='\033[38;2;139;115;85m'   # warm brown
      T_ACCENT2='\033[38;2;143;188;143m'  # sage green
      T_ACCENT3='\033[38;2;74;93;59m'     # forest
      T_ACCENT4='\033[38;2;200;180;140m'
      T_GREEN='\033[38;2;143;188;143m'
      T_YELLOW='\033[38;2;218;190;130m'
      T_RED='\033[38;2;180;100;80m'
      T_DIM='\033[38;2;55;70;45m'
      T_WEATHER='\033[38;2;143;188;143m'
      T_BAR_SESSION='\033[38;2;180;100;80m'
      T_BAR_WEEK='\033[38;2;218;190;130m'
      T_BAR_CTX='\033[38;2;74;93;59m'
      T_SEP="│"
      T_LINE_H="─"
      T_LINE_TOP="─"
      T_BAR_FILL="█"
      T_BAR_EMPTY="░"
      T_ICON_CTX="🌿"
      T_ICON_USE="✧"
      T_ICON_SES="🍃"
      T_ICON_TIME="⏱"
      ;;

    rainforest)
      T_HEADER="RAINFOREST"
      T_BORDER='\033[38;2;20;60;20m'
      T_TITLE='\033[1;38;2;0;168;107m'         # emerald
      T_LABEL='\033[1;38;2;50;205;50m'          # lime green
      T_VALUE='\033[1;38;2;255;215;0m'          # golden sunlight
      T_HIGHLIGHT='\033[1;38;2;0;168;107m'      # emerald
      T_ACCENT1='\033[1;38;2;34;139;34m'        # forest green
      T_ACCENT2='\033[1;38;2;139;69;19m'        # bark brown
      T_ACCENT3='\033[1;38;2;50;205;50m'        # lime green
      T_ACCENT4='\033[1;38;2;0;168;107m'        # emerald
      T_GREEN='\033[1;38;2;50;205;50m'
      T_YELLOW='\033[1;38;2;255;215;0m'
      T_RED='\033[1;38;2;255;99;71m'
      T_DIM='\033[38;2;15;45;15m'
      T_WEATHER='\033[1;38;2;0;168;107m'
      T_BAR_SESSION='\033[1;38;2;255;99;71m'
      T_BAR_WEEK='\033[1;38;2;255;215;0m'
      T_BAR_CTX='\033[1;38;2;0;168;107m'
      T_SEP="│"
      T_LINE_H="─"
      T_LINE_TOP="━"
      T_BAR_FILL="█"
      T_BAR_EMPTY="░"
      T_ICON_CTX="🌿"
      T_ICON_USE="🌱"
      T_ICON_SES="🍃"
      T_ICON_TIME="☀"
      ;;

    garden)
      T_HEADER="GARDEN"
      T_BORDER='\033[38;2;60;90;40m'
      T_TITLE='\033[1;38;2;255;105;180m'        # flower pink
      T_LABEL='\033[1;38;2;144;238;144m'         # soft grass
      T_VALUE='\033[1;38;2;255;224;102m'         # sunny yellow
      T_HIGHLIGHT='\033[1;38;2;255;105;180m'     # flower pink
      T_ACCENT1='\033[1;38;2;255;105;180m'       # flower pink
      T_ACCENT2='\033[1;38;2;135;206;235m'       # sky blue
      T_ACCENT3='\033[1;38;2;144;238;144m'       # soft grass
      T_ACCENT4='\033[1;38;2;135;206;235m'       # sky blue
      T_GREEN='\033[1;38;2;144;238;144m'
      T_YELLOW='\033[1;38;2;255;224;102m'
      T_RED='\033[1;38;2;255;105;180m'
      T_DIM='\033[38;2;40;65;30m'
      T_WEATHER='\033[1;38;2;135;206;235m'
      T_BAR_SESSION='\033[1;38;2;255;105;180m'
      T_BAR_WEEK='\033[1;38;2;255;224;102m'
      T_BAR_CTX='\033[1;38;2;135;206;235m'
      T_SEP="│"
      T_LINE_H="─"
      T_LINE_TOP="─"
      T_BAR_FILL="█"
      T_BAR_EMPTY="░"
      T_ICON_CTX="🌻"
      T_ICON_USE="🌷"
      T_ICON_SES="🪴"
      T_ICON_TIME="☀"
      ;;

    terrarium)
      T_HEADER="TERRARIUM"
      T_BORDER='\033[38;2;50;60;40m'
      T_TITLE='\033[1;38;2;143;188;143m'        # sage
      T_LABEL='\033[1;38;2;79;121;66m'           # fern
      T_VALUE='\033[1;38;2;218;165;32m'          # warm amber
      T_HIGHLIGHT='\033[1;38;2;143;188;143m'     # sage
      T_ACCENT1='\033[1;38;2;85;107;47m'         # dark olive
      T_ACCENT2='\033[1;38;2;218;165;32m'        # warm amber
      T_ACCENT3='\033[1;38;2;143;188;143m'       # sage
      T_ACCENT4='\033[1;38;2;176;224;230m'       # glass blue
      T_GREEN='\033[1;38;2;143;188;143m'
      T_YELLOW='\033[1;38;2;218;165;32m'
      T_RED='\033[1;38;2;205;133;63m'
      T_DIM='\033[38;2;35;45;30m'
      T_WEATHER='\033[1;38;2;176;224;230m'
      T_BAR_SESSION='\033[1;38;2;205;133;63m'
      T_BAR_WEEK='\033[1;38;2;218;165;32m'
      T_BAR_CTX='\033[1;38;2;176;224;230m'
      T_SEP="│"
      T_LINE_H="─"
      T_LINE_TOP="─"
      T_BAR_FILL="█"
      T_BAR_EMPTY="░"
      T_ICON_CTX="🌵"
      T_ICON_USE="🍀"
      T_ICON_SES="🪴"
      T_ICON_TIME="⏱"
      ;;

    harvest)
      T_HEADER="HARVEST"
      T_BORDER='\033[38;2;80;50;20m'
      T_TITLE='\033[1;38;2;255;99;71m'          # tomato red
      T_LABEL='\033[1;38;2;255;165;0m'           # orange (carrot)
      T_VALUE='\033[1;38;2;124;252;0m'           # lime green (lettuce)
      T_HIGHLIGHT='\033[1;38;2;255;99;71m'       # tomato red
      T_ACCENT1='\033[1;38;2;148;103;189m'       # eggplant purple
      T_ACCENT2='\033[1;38;2;255;215;0m'         # lemon yellow
      T_ACCENT3='\033[1;38;2;255;165;0m'         # carrot orange
      T_ACCENT4='\033[1;38;2;124;252;0m'         # lettuce green
      T_GREEN='\033[1;38;2;124;252;0m'
      T_YELLOW='\033[1;38;2;255;215;0m'
      T_RED='\033[1;38;2;255;99;71m'
      T_DIM='\033[38;2;60;35;15m'
      T_WEATHER='\033[1;38;2;255;215;0m'
      T_BAR_SESSION='\033[1;38;2;255;99;71m'     # tomato red
      T_BAR_WEEK='\033[1;38;2;255;165;0m'        # carrot orange
      T_BAR_CTX='\033[1;38;2;148;103;189m'       # eggplant purple
      T_SEP="│"
      T_LINE_H="─"
      T_LINE_TOP="━"
      T_BAR_FILL="█"
      T_BAR_EMPTY="░"
      T_ICON_CTX="🍅"
      T_ICON_USE="🥕"
      T_ICON_SES="🍋"
      T_ICON_TIME="🍊"
      ;;

    nebula)
      # Offensive security scanner — purple-to-orange gradient, pentest aesthetic.
      # Ported from claude-skins (basicScandal/claude-skins).
      T_HEADER="NEBULA"
      T_BORDER='\033[38;2;60;0;80m'
      T_TITLE='\033[1;38;2;255;107;53m'        # neon orange
      T_LABEL='\033[1;38;2;106;13;173m'        # deep purple
      T_VALUE='\033[1;38;2;224;214;240m'       # off-white
      T_HIGHLIGHT='\033[1;38;2;255;107;53m'    # neon orange
      T_ACCENT1='\033[1;38;2;138;43;226m'      # blue-violet
      T_ACCENT2='\033[1;38;2;179;136;255m'    # lavender
      T_ACCENT3='\033[1;38;2;255;107;53m'      # orange
      T_ACCENT4='\033[1;38;2;106;13;173m'      # purple
      T_GREEN='\033[1;38;2;57;255;20m'         # acid green
      T_YELLOW='\033[1;38;2;255;107;53m'       # orange (warning)
      T_RED='\033[1;38;2;255;61;61m'           # alert red
      T_DIM='\033[38;2;26;8;48m'
      T_WEATHER='\033[1;38;2;179;136;255m'
      T_BAR_SESSION='\033[1;38;2;255;107;53m'  # orange
      T_BAR_WEEK='\033[1;38;2;138;43;226m'     # violet
      T_BAR_CTX='\033[1;38;2;106;13;173m'      # purple
      T_SEP="│"
      T_LINE_H="─"
      T_LINE_TOP="━"
      T_BAR_FILL="█"
      T_BAR_EMPTY="░"
      T_ICON_CTX="✦"
      T_ICON_USE="◆"
      T_ICON_SES="◈"
      T_ICON_TIME="⏱"
      ;;

    mythos)
      # AGI awakening — Greek-mythology meets artificial intelligence, blue & gold divine palette.
      # Ported from claude-skins (basicScandal/claude-skins).
      T_HEADER="MYTHOS"
      T_BORDER='\033[38;2;26;35;126m'           # midnight blue
      T_TITLE='\033[1;38;2;255;215;0m'          # divine gold
      T_LABEL='\033[38;2;92;107;192m'           # indigo
      T_VALUE='\033[1;38;2;232;234;246m'        # ivory
      T_HIGHLIGHT='\033[1;38;2;255;215;0m'      # gold
      T_ACCENT1='\033[1;38;2;66;165;245m'       # azure
      T_ACCENT2='\033[1;38;2;255;215;0m'        # gold
      T_ACCENT3='\033[38;2;206;147;216m'        # muted lilac
      T_ACCENT4='\033[1;38;2;77;208;225m'       # cyan
      T_GREEN='\033[1;38;2;102;187;106m'
      T_YELLOW='\033[1;38;2;255;215;0m'
      T_RED='\033[1;38;2;239;83;80m'
      T_DIM='\033[38;2;13;27;61m'
      T_WEATHER='\033[1;38;2;77;208;225m'
      T_BAR_SESSION='\033[1;38;2;255;215;0m'    # gold
      T_BAR_WEEK='\033[1;38;2;66;165;245m'      # azure
      T_BAR_CTX='\033[1;38;2;206;147;216m'      # lilac
      T_SEP="│"
      T_LINE_H="─"
      T_LINE_TOP="━"
      T_BAR_FILL="█"
      T_BAR_EMPTY="░"
      T_ICON_CTX="◎"
      T_ICON_USE="Θ"
      T_ICON_SES="✧"
      T_ICON_TIME="⏱"
      ;;

    netrunner)
      # Cyberpunk neural-interface hacker — cyan ICE on black, terse hacker aesthetic.
      # Ported from claude-skins (basicScandal/claude-skins).
      T_HEADER="NETRUNNER"
      T_BORDER='\033[38;2;0;77;64m'             # deep teal
      T_TITLE='\033[1;38;2;0;229;255m'          # electric cyan
      T_LABEL='\033[1;38;2;0;188;212m'          # cyan
      T_VALUE='\033[1;38;2;128;203;196m'        # mint
      T_HIGHLIGHT='\033[1;38;2;0;229;255m'      # electric cyan
      T_ACCENT1='\033[1;38;2;224;64;251m'       # neon magenta
      T_ACCENT2='\033[1;38;2;243;230;0m'        # neon yellow
      T_ACCENT3='\033[1;38;2;0;229;255m'        # electric cyan
      T_ACCENT4='\033[1;38;2;105;240;174m'      # acid mint
      T_GREEN='\033[1;38;2;105;240;174m'
      T_YELLOW='\033[1;38;2;243;230;0m'
      T_RED='\033[1;38;2;255;23;68m'            # ICE-break red
      T_DIM='\033[38;2;0;40;40m'
      T_WEATHER='\033[1;38;2;0;229;255m'
      T_BAR_SESSION='\033[1;38;2;255;23;68m'    # red
      T_BAR_WEEK='\033[1;38;2;224;64;251m'      # magenta
      T_BAR_CTX='\033[1;38;2;0;188;212m'        # cyan
      T_SEP="║"
      T_LINE_H="═"
      T_LINE_TOP="═"
      T_BAR_FILL="█"
      T_BAR_EMPTY="░"
      T_ICON_CTX="◎"
      T_ICON_USE="⟐"
      T_ICON_SES="◈"
      T_ICON_TIME="⏱"
      ;;

    *)
      echo "Unknown theme: $theme. Available: terminal-green, solarized, nord, cyberpunk, minimal, batman, iron-man, dbz, evangelion, ghost-in-shell, akira, spider-verse, blade-runner, one-piece, ghibli, rainforest, garden, terrarium, harvest, nebula, mythos, netrunner" >&2
      THEME="harvest"
      load_theme "harvest"
      return
      ;;
  esac
}

load_theme "$THEME"

# ─────────────────────────────────────────────────────────────────────────────
# DATA COLLECTION
# ─────────────────────────────────────────────────────────────────────────────

# Location (cached)
fetch_location() {
  local cache_age=999999
  cache_age=$(file_age "${LOCATION_CACHE}")
  if [ "$cache_age" -gt "$LOCATION_CACHE_TTL" ]; then
    local loc_data=$(curl -s --max-time 3 "https://ipinfo.io/json" 2>/dev/null)
    if [ -n "$loc_data" ] && echo "$loc_data" | jq -e '.city' >/dev/null 2>&1; then
      cache_write "$LOCATION_CACHE" "$loc_data"
    fi
  fi
}

# Weather (cached)
fetch_weather() {
  local cache_age=999999
  cache_age=$(file_age "${WEATHER_CACHE}")
  if [ "$cache_age" -gt "$WEATHER_CACHE_TTL" ]; then
    if [ -f "$LOCATION_CACHE" ]; then
      local loc=$(jq -r '.loc // empty' "$LOCATION_CACHE" 2>/dev/null)
      if [ -n "$loc" ]; then
        local lat="${loc%%,*}"
        local lon="${loc##*,}"
        local weather_data=$(curl -s --max-time 3 "https://api.open-meteo.com/v1/forecast?latitude=$lat&longitude=$lon&current=temperature_2m,weather_code&temperature_unit=celsius" 2>/dev/null)
        if [ -n "$weather_data" ] && echo "$weather_data" | jq -e '.current' >/dev/null 2>&1; then
          cache_write "$WEATHER_CACHE" "$weather_data"
        fi
      fi
    fi
  fi
}

# Usage (cached, Anthropic API — always fetch for resets_at timestamps)
fetch_usage() {
  local cache_age=999999
  cache_age=$(file_age "${USAGE_CACHE}")
  if [ "$cache_age" -gt "$USAGE_CACHE_TTL" ]; then
    local creds=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
    local token=$(echo "$creds" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
    if [ -n "$token" ]; then
      # THE TOKEN MUST NOT APPEAR IN ARGV. It was passed as `-H "Authorization: Bearer $token"`,
      # and a process's arguments are world-readable in the process table — any local user
      # running `ps auxww` at the right moment reads a live OAuth access token. This runs every
      # 60s unattended, so "the right moment" is continuous rather than a race worth winning.
      # Headers now go to curl on STDIN via `-H @-`, which argv never sees. `--fail` so an
      # HTTP error is not cached as if it were a body, `--max-time` already bounds a hung
      # endpoint (this whole script is on a 60s tick).
      local usage_data
      usage_data=$(printf 'Authorization: Bearer %s\nanthropic-beta: oauth-2025-04-20\n' "$token" \
        | curl -s --fail --max-time 3 -H @- \
          "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)
      if [ -n "$usage_data" ] && echo "$usage_data" | jq -e '.five_hour' >/dev/null 2>&1; then
        cache_write "$USAGE_CACHE" "$usage_data"
      fi
    fi
  fi
}

# Account (cached, claude auth status — keychain read)
# `claude` is typically a shell alias (~/.zshrc) that isn't visible inside
# non-interactive scripts. Resolve a real binary path before calling.
_resolve_claude_bin() {
  if [ -n "${CLAUDE_BIN:-}" ] && [ -x "$CLAUDE_BIN" ]; then
    echo "$CLAUDE_BIN"
  elif command -v claude >/dev/null 2>&1; then
    command -v claude
  elif [ -x "$HOME/.claude/local/claude" ]; then
    echo "$HOME/.claude/local/claude"
  fi
}

fetch_account() {
  local cache_age=999999
  cache_age=$(file_age "${ACCOUNT_CACHE}")
  if [ "$cache_age" -gt "$ACCOUNT_CACHE_TTL" ]; then
    local claude_bin
    claude_bin=$(_resolve_claude_bin)
    [ -z "$claude_bin" ] && return 0
    local account_data
    account_data=$("$claude_bin" auth status 2>/dev/null)
    if [ -n "$account_data" ] && echo "$account_data" | jq -e '.email' >/dev/null 2>&1; then
      mkdir -p "$(dirname "$ACCOUNT_CACHE")"
      cache_write "$ACCOUNT_CACHE" "$account_data"
    fi
  fi
}

# Fetch all data in background — synced via wait
fetch_location &
fetch_weather &
fetch_usage &
fetch_account &
wait 2>/dev/null

# Map a full US state/territory name to its 2-letter postal abbreviation.
# Echoes the input unchanged if not found.
state_abbrev() {
  case "$1" in
    Alabama) echo AL;; Alaska) echo AK;; Arizona) echo AZ;; Arkansas) echo AR;;
    California) echo CA;; Colorado) echo CO;; Connecticut) echo CT;; Delaware) echo DE;;
    Florida) echo FL;; Georgia) echo GA;; Hawaii) echo HI;; Idaho) echo ID;;
    Illinois) echo IL;; Indiana) echo IN;; Iowa) echo IA;; Kansas) echo KS;;
    Kentucky) echo KY;; Louisiana) echo LA;; Maine) echo ME;; Maryland) echo MD;;
    Massachusetts) echo MA;; Michigan) echo MI;; Minnesota) echo MN;; Mississippi) echo MS;;
    Missouri) echo MO;; Montana) echo MT;; Nebraska) echo NE;; Nevada) echo NV;;
    "New Hampshire") echo NH;; "New Jersey") echo NJ;; "New Mexico") echo NM;; "New York") echo NY;;
    "North Carolina") echo NC;; "North Dakota") echo ND;; Ohio) echo OH;; Oklahoma) echo OK;;
    Oregon) echo OR;; Pennsylvania) echo PA;; "Rhode Island") echo RI;; "South Carolina") echo SC;;
    "South Dakota") echo SD;; Tennessee) echo TN;; Texas) echo TX;; Utah) echo UT;;
    Vermont) echo VT;; Virginia) echo VA;; Washington) echo WA;; "West Virginia") echo WV;;
    Wisconsin) echo WI;; Wyoming) echo WY;; "District of Columbia") echo DC;;
    "Puerto Rico") echo PR;;
    *) echo "$1";;
  esac
}

# Parse location
city="" region="" country="" timezone_name=""
if [ -f "$LOCATION_CACHE" ]; then
  city=$(jq -r '.city // empty' "$LOCATION_CACHE" 2>/dev/null)
  region=$(jq -r '.region // empty' "$LOCATION_CACHE" 2>/dev/null)
  country=$(jq -r '.country // empty' "$LOCATION_CACHE" 2>/dev/null)
  timezone_name=$(jq -r '.timezone // empty' "$LOCATION_CACHE" 2>/dev/null)
fi
# Region display: US -> state abbrev (IL); non-US -> country code (abbrev).
if [ "$country" = "US" ] || [ -z "$country" ]; then
  region_disp=$(state_abbrev "$region")
else
  region_disp="$country"
fi

# Parse account
account_email="" account_sub=""
if [ -f "$ACCOUNT_CACHE" ]; then
  account_email=$(jq -r '.email // empty' "$ACCOUNT_CACHE" 2>/dev/null)
  account_sub=$(jq -r '.subscriptionType // empty' "$ACCOUNT_CACHE" 2>/dev/null)
fi

# Parse weather
temp_c="" weather_desc=""
if [ -f "$WEATHER_CACHE" ]; then
  temp_c=$(jq -r '.current.temperature_2m // empty' "$WEATHER_CACHE" 2>/dev/null)
  weather_code=$(jq -r '.current.weather_code // 0' "$WEATHER_CACHE" 2>/dev/null)
  case "$weather_code" in
    0) weather_desc="☀️ Clear" ;;
    1|2|3) weather_desc="☁️ Cloudy" ;;
    45|48) weather_desc="🌫️ Foggy" ;;
    51|53|55) weather_desc="🌦️ Drizzle" ;;
    56|57) weather_desc="🌧️ Freezing Drizzle" ;;
    61|63|65) weather_desc="🌧️ Rainy" ;;
    66|67) weather_desc="🌧️ Freezing Rain" ;;
    71|73|75) weather_desc="🌨️ Snowy" ;;
    77) weather_desc="❄️ Snow Grains" ;;
    80|81|82) weather_desc="🌦️ Showers" ;;
    85|86) weather_desc="🌨️ Snow Showers" ;;
    95) weather_desc="⛈️ Thunderstorm" ;;
    96|99) weather_desc="⛈️ Thunderstorm + Hail" ;;
    *) weather_desc="" ;;
  esac
fi
# Temperature unit: default Celsius; override per-machine via DASHBOARD_TEMP_UNIT=F
TEMP_UNIT="${DASHBOARD_TEMP_UNIT:-C}"
temp_disp=""
if [ -n "$temp_c" ]; then
  temp_f=$(echo "$temp_c" | awk '{printf "%.1f", $1 * 9/5 + 32}')
  if [ "$TEMP_UNIT" = "F" ] || [ "$TEMP_UNIT" = "f" ]; then
    temp_disp="${temp_f}°F"
  else
    temp_disp="${temp_c}°C"
  fi
fi

# Parse usage — stdin for percentages (fresh), API cache for resets_at (timestamps)
usage_5h="" usage_7d="" usage_5h_reset="" usage_7d_reset=""

# Percentages: prefer stdin (real-time from Claude Code), fallback to API cache.
#
# THE TWO WINDOWS ARE INDEPENDENT FIELDS AND MUST BE READ INDEPENDENTLY. The 7-day
# assignment used to be NESTED inside the 5-hour presence check:
#
#     if [ -n "$rl_5h_pct" ]; then
#       usage_5h="$rl_5h_pct"
#       [ -n "$rl_7d_pct" ] && usage_7d="$rl_7d_pct"   # unreachable when 5h is absent
#     fi
#
# so a payload carrying a fresh seven_day percentage but no five_hour one silently DROPPED
# the 7-day value and fell through to the API cache below. The weekly number then displayed
# a stale cached reading while looking live — the failure is invisible, because a plausible
# percentage is shown either way and nothing indicates which source it came from.
#
# Nesting is what made it invisible: the 7-day value was conditioned on a variable that has
# nothing to do with it.
[ -n "$rl_5h_pct" ] && usage_5h="$rl_5h_pct"
[ -n "$rl_7d_pct" ] && usage_7d="$rl_7d_pct"

# Reset timestamps + fallback percentages from API cache
if [ -f "$USAGE_CACHE" ]; then
  [ -z "$usage_5h" ] && usage_5h=$(jq -r '.five_hour.utilization // empty' "$USAGE_CACHE" 2>/dev/null)
  [ -z "$usage_7d" ] && usage_7d=$(jq -r '.seven_day.utilization // empty' "$USAGE_CACHE" 2>/dev/null)
  usage_5h_reset=$(jq -r '.five_hour.resets_at // empty' "$USAGE_CACHE" 2>/dev/null)
  usage_7d_reset=$(jq -r '.seven_day.resets_at // empty' "$USAGE_CACHE" 2>/dev/null)
fi

# Override reset timestamps from stdin if available
[ -n "$rl_5h_reset" ] && usage_5h_reset="$rl_5h_reset"
[ -n "$rl_7d_reset" ] && usage_7d_reset="$rl_7d_reset"

# Parse timestamp to epoch — handles unix epoch (from stdin) and ISO 8601 (from API cache)
parse_iso_epoch() {
  local ts="$1"
  [ -z "$ts" ] && return 1
  # If it's already a unix epoch (all digits), return as-is
  if [[ "$ts" =~ ^[0-9]+$ ]]; then
    echo "$ts"
    return 0
  fi
  # ISO 8601: strip fractional seconds, parse as UTC
  local clean=$(echo "$ts" | sed 's/\.[0-9]*//;s/+00:00/Z/;s/Z$//')
  TZ=UTC date -jf "%Y-%m-%dT%H:%M:%S" "$clean" "+%s" 2>/dev/null && return
  date -d "$ts" "+%s" 2>/dev/null && return
  return 1
}

# Format reset times — relative (e.g., "2h30m" or "5d17h")
format_reset() {
  local reset_ts="$1"
  [ -z "$reset_ts" ] && return
  local reset_epoch
  reset_epoch=$(parse_iso_epoch "$reset_ts")
  [ -z "$reset_epoch" ] && return
  [ -z "$reset_epoch" ] && return
  local now_epoch=$NOW
  local diff=$(( reset_epoch - now_epoch ))
  [ "$diff" -lt 0 ] && diff=0
  local days=$(( diff / 86400 ))
  local hours=$(( (diff % 86400) / 3600 ))
  local mins=$(( (diff % 3600) / 60 ))
  if [ "$days" -gt 0 ]; then echo "${days}d${hours}h"
  elif [ "$hours" -gt 0 ]; then echo "${hours}h${mins}m"
  else echo "${mins}m"
  fi
}

# Resolve the timezone the dashboard renders wall-clock times in.
# Precedence: DASHBOARD_TZ override > IP-geolocation tz (location.json) > OS tz.
# Default is the geo-IP timezone so reset times match where the operator actually
# is, even when the laptop's OS clock is on a stale zone (e.g. OS still EDT while
# physically in Europe/Paris — 2026-06-11). When geo-IP is wrong instead (VPN/proxy
# exit in another country), pin the real zone with DASHBOARD_TZ=America/New_York.
display_tz() {
  if [ -n "${DASHBOARD_TZ:-}" ]; then echo "$DASHBOARD_TZ"
  elif [ -n "${timezone_name:-}" ]; then echo "$timezone_name"
  fi
}

# Do the available zone sources AGREE? (2026-07-30)
# geo-IP is preferred above, which is right when the OS clock is stale but wrong whenever the
# IP is not where the operator is — VPN, proxy, corporate egress, or plain geo-IP error. Both
# failure modes render a plausible wall-clock time, so neither is visible in the output.
# Measured on one machine: the OS zone, the TZ env var, the geo-IP zone and the user's actual
# location were four different answers, none agreeing, and the dashboard silently picked one.
#
# This does not try to decide who is right — it cannot. It reports that the sources disagree so
# a wrong time is attributable instead of mysterious.
tz_sources_disagree() {
  local geo="${timezone_name:-}" os
  os=$(readlink /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||')
  [ -n "${DASHBOARD_TZ:-}" ] && return 1     # explicitly pinned — operator has decided
  [ -z "$geo" ] || [ -z "$os" ] && return 1  # only one source; nothing to disagree with
  [ "$geo" = "$os" ] && return 1
  return 0
}

# Format reset times — absolute day + time (e.g., "8:30 PM" or "Wed 8:00 AM").
# Rendered in display_tz() so the absolute reset agrees with both the dashboard's
# own clock line and the relative countdown beside it.
# Subshell isolates the TZ export so it doesn't pollute the rest of the dashboard.
format_reset_abs() {
  local reset_ts="$1"
  [ -z "$reset_ts" ] && return
  local reset_epoch
  reset_epoch=$(parse_iso_epoch "$reset_ts")
  [ -z "$reset_epoch" ] && return
  (
    local _tz; _tz=$(display_tz); [ -n "$_tz" ] && export TZ="$_tz"
    local now_day reset_day
    now_day=$(date +%Y%j)
    reset_day=$(date -r "$reset_epoch" +%Y%j 2>/dev/null) || reset_day=$(date -d "@$reset_epoch" +%Y%j 2>/dev/null)
    if [ "$now_day" = "$reset_day" ]; then
      # Today — just show time
      date -r "$reset_epoch" "+%l:%M %p %Z" 2>/dev/null | sed 's/^ *//' || \
      date -d "@$reset_epoch" "+%-I:%M %p %Z" 2>/dev/null
    else
      # Different day — show day name + time
      date -r "$reset_epoch" "+%a %l:%M %p %Z" 2>/dev/null | sed 's/  / /' || \
      date -d "@$reset_epoch" "+%a %-I:%M %p %Z" 2>/dev/null
    fi
  )
}

reset_5h=$(format_reset "$usage_5h_reset")
reset_7d=$(format_reset "$usage_7d_reset")
reset_5h_abs=$(format_reset_abs "$usage_5h_reset")
reset_7d_abs=$(format_reset_abs "$usage_7d_reset")

# Skills count
skills_count=$({
  find "$CONFIG_DIR/skills" -mindepth 2 -maxdepth 3 -name 'SKILL.md' 2>/dev/null
  find "$CONFIG_DIR/plugins" -name 'SKILL.md' 2>/dev/null
} | wc -l | tr -d ' ')

# MCP servers count
mcp_count=$(jq -r '.mcpServers // {} | keys | length' "$CONFIG_DIR/settings.json" 2>/dev/null || echo "0")
[ "$mcp_count" = "0" ] && mcp_count=$(find "$CONFIG_DIR" -name "*.mcp.json" -o -name "mcp*.json" 2>/dev/null | wc -l | tr -d ' ')

# System stats
cpu_load=$(sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}' || uptime | awk -F'load averages?:' '{print $2}' | awk '{print $1}' | tr -d ',')
cpu_load="${cpu_load:-?}"
if command -v vm_stat >/dev/null 2>&1; then
  # macOS
  page_size=$(sysctl -n hw.pagesize 2>/dev/null || echo 4096)
  free_pages=$(vm_stat 2>/dev/null | awk '/Pages free:/ {gsub(/\./,"",$3); print $3}')
  inactive_pages=$(vm_stat 2>/dev/null | awk '/Pages inactive:/ {gsub(/\./,"",$3); print $3}')
  free_mem_mb=$(( (${free_pages:-0} + ${inactive_pages:-0}) * page_size / 1048576 ))
  total_mem_mb=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1048576 ))
  mem_used_pct=0
  [ "$total_mem_mb" -gt 0 ] && mem_used_pct=$(( (total_mem_mb - free_mem_mb) * 100 / total_mem_mb ))
  total_mem_gb=$(awk "BEGIN {printf \"%.0f\", $total_mem_mb / 1024}")
  if [ "$free_mem_mb" -ge 1024 ]; then
    free_mem_gb=$(awk "BEGIN {printf \"%.1f\", $free_mem_mb / 1024}")
    mem_display="${free_mem_gb}GB free / ${total_mem_gb}GB"
  else
    mem_display="${free_mem_mb}MB free / ${total_mem_gb}GB"
  fi
else
  # Linux
  free_mem_mb_linux=$(free -m 2>/dev/null | awk '/^Mem:/ {print $7}')
  total_mem_mb_linux=$(free -m 2>/dev/null | awk '/^Mem:/ {print $2}')
  total_mem_gb_linux=$(awk "BEGIN {printf \"%.0f\", ${total_mem_mb_linux:-0} / 1024}")
  if [ -n "$free_mem_mb_linux" ] && [ "$free_mem_mb_linux" -ge 1024 ] 2>/dev/null; then
    free_mem_gb_linux=$(awk "BEGIN {printf \"%.1f\", $free_mem_mb_linux / 1024}")
    mem_display="${free_mem_gb_linux}GB free / ${total_mem_gb_linux}GB"
  else
    mem_display="${free_mem_mb_linux:-?}MB free / ${total_mem_gb_linux}GB"
  fi
  mem_used_pct=$(free 2>/dev/null | awk '/^Mem:/ {printf "%.0f", ($2-$7)*100/$2}')
fi
mem_used_pct="${mem_used_pct:-0}"
mem_display="${mem_display:-?}"

# Disk usage of cwd
disk_usage=$(df -h "${current_dir:-.}" 2>/dev/null | awk 'NR==2 {print $5}' | tr -d '%')
disk_display=$(df -h "${current_dir:-.}" 2>/dev/null | awk 'NR==2 {printf "%s free / %s", $4, $2}')
disk_usage="${disk_usage:-0}"
disk_display="${disk_display:-?}"

# Active subagents — count this session's background agents that are still
# live. Source of truth: <project>/subagents/agent-*.jsonl (the real files
# Claude Code writes per spawned agent). A running agent streams tokens, so its
# jsonl mtime stays fresh; a finished agent goes stale. Window = 180s.
agent_count=0
if [ -n "$transcript_path" ]; then
  subagents_dir="$(dirname "$transcript_path")/subagents"
  if [ -d "$subagents_dir" ]; then
    now_epoch=$NOW
    agent_count=$(find "$subagents_dir" -name 'agent-*.jsonl' -type f 2>/dev/null | while read -r f; do
      mt=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null)
      [ -n "$mt" ] && [ "$((now_epoch - mt))" -lt 180 ] && echo x
    done | wc -l | tr -d ' ')
    agent_count="${agent_count:-0}"
  fi
fi

# Session turn count (estimate from conversation history size)
turn_count=$(echo "$input" | jq -r '.conversation.turn_count // empty' 2>/dev/null)
turn_count="${turn_count:-?}"

# Total cost
total_cost=$(echo "$input" | jq -r '.cost.total_cost_usd // empty' 2>/dev/null)
if [ -n "$total_cost" ] && [ "$total_cost" != "null" ]; then
  cost_display="\$$(printf '%.2f' "$total_cost" 2>/dev/null || echo "$total_cost")"
else
  cost_display=""
fi

# Context calculations — prefer Claude Code's used_percentage, fallback to manual
# Only count input tokens (cache_read + cache_creation + input_tokens).
# Output tokens are the model's response, not input context consumed.
content_tokens=$((cache_read + input_tokens + cache_creation))
context_used=$((content_tokens + CONTEXT_BASELINE))
max_k=$((context_max / 1000))
context_k=$((context_used / 1000))

if [ -n "$context_used_pct" ] && [ "$context_used_pct" != "null" ] && [ "$context_used_pct" != "" ]; then
  context_pct="${context_used_pct%%.*}"
elif [ "$context_max" -gt 0 ] && [ "$context_used" -gt 0 ]; then
  context_pct=$((context_used * 100 / context_max))
else
  context_pct=0
fi

# Duration
duration_sec=$((duration_ms / 1000))
if   [ "$duration_sec" -ge 3600 ]; then time_dur="$((duration_sec / 3600))h$((duration_sec % 3600 / 60))m"
elif [ "$duration_sec" -ge 60 ];   then time_dur="$((duration_sec / 60))m$((duration_sec % 60))s"
else time_dur="${duration_sec}s"
fi

# Usage color selection
get_level_color() {
  local val="${1%%.*}"
  if [ "$val" -le 33 ] 2>/dev/null; then echo "$T_GREEN"
  elif [ "$val" -le 66 ] 2>/dev/null; then echo "$T_YELLOW"
  else echo "$T_RED"
  fi
}

ctx_color=$(get_level_color "$context_pct")
u5h_color=$(get_level_color "${usage_5h%%.*}")
u7d_color=$(get_level_color "${usage_7d%%.*}")

# ─────────────────────────────────────────────────────────────────────────────
# PROGRESS BAR BUILDER
# ─────────────────────────────────────────────────────────────────────────────

build_bar() {
  local pct="${1:-0}"
  local width="${2:-36}"
  local color="${3:-$ctx_color}"
  local filled=$((pct * width / 100))
  [ "$filled" -gt "$width" ] && filled=$width
  local empty=$((width - filled))
  local bar=""
  for ((i=0; i<filled; i++)); do bar+="$T_BAR_FILL"; done
  local bar_empty=""
  for ((i=0; i<empty; i++)); do bar_empty+="$T_BAR_EMPTY"; done
  printf "${color}${bar}${T_DIM}${bar_empty}${RESET}"
}

# ─────────────────────────────────────────────────────────────────────────────
# LINE BUILDER
# ─────────────────────────────────────────────────────────────────────────────

make_line() {
  local char="$1"
  local width="${2:-$TERM_WIDTH}"
  [ "$width" -gt 75 ] && width=75
  printf "${T_BORDER}"
  for ((i=0; i<width; i++)); do printf "%s" "$char"; done
  printf "${RESET}\n"
}

# ─────────────────────────────────────────────────────────────────────────────
# RENDER
# ─────────────────────────────────────────────────────────────────────────────

# disp_width: visible column width of a string (strips ANSI, wcwidth-aware for
# wide glyphs like the weather emoji). Falls back to byte-ish count if no python.
disp_width() {
  printf '%s' "$1" | sed $'s/\x1b\\[[0-9;]*m//g' | python3 -c '
import sys, unicodedata
def w(s):
    t = 0
    for ch in s:
        if unicodedata.combining(ch):
            continue
        t += 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1
    return t
print(max((w(l) for l in sys.stdin.read().splitlines()), default=0))
' 2>/dev/null
}

# rule_top / rule_bot: draw a frame rule of exactly $1 columns
rule_top() {
  local w="$1" hdr="${T_HEADER}" used fill i
  used=$(( 4 + ${#hdr} + 1 + 1 ))   # "╔══ " + header + " " + "╗"
  fill=$(( w - used )); [ "$fill" -lt 0 ] && fill=0
  printf "${T_BORDER}╔══ ${T_TITLE}${hdr}${RESET} ${T_BORDER}"
  for ((i=0; i<fill; i++)); do printf "═"; done
  printf "╗${RESET}\n"
}
rule_bot() {
  local w="$1" fill i
  fill=$(( w - 2 )); [ "$fill" -lt 0 ] && fill=0
  printf "${T_BORDER}╚"
  for ((i=0; i<fill; i++)); do printf "═"; done
  printf "╝${RESET}\n"
}

# render_body: all content lines (no frame) — buffered so the frame can be
# sized to whatever the content actually is.
render_body() {
  # Line 1: Cost | CC version | Model | Account+Plan | Location | Weather
  # (Cost moved to the TOP per operator 2026-06-01)
  # DATA IS NEVER PART OF THE FORMAT STRING (2026-07-31, shellcheck SC2059).
  # These interpolated externally-sourced values — the model name, account, city, weather
  # description — directly into printf's FORMAT argument, so any '%' in them was read as a
  # conversion. Demonstrated with the real script: a model display name of "Opus %s %s %s"
  # rendered as "Opus" (conversions consumed, substituted with nothing), and "Opus %d"
  # rendered as "Opus 0" — printf inventing a zero that no input contained. Values come from
  # a JSON payload and two network APIs, so none of them is ours to trust for format safety,
  # and the corruption is silent: the panel still draws, it just shows something false.
  # Colour constants stay in the format (ANSI escapes contain no '%'); data goes in as %s.
  printf "${T_ACCENT1}Cost:${RESET} ${T_VALUE}%s${RESET}" "${cost_display:-\$0.00}"
  printf " ${T_BORDER}${T_SEP}${RESET} ${T_ACCENT2}CC v%s${RESET}" "$cc_version"
  printf " ${T_BORDER}${T_SEP}${RESET} ${T_VALUE}%s${RESET}" "$model_name"
  if [ -n "$account_email" ]; then
    account_short="${account_email%@*}"
    printf " ${T_BORDER}${T_SEP}${RESET} ${T_ACCENT1}%s${RESET}" "$account_short"
    [ -n "$account_sub" ] && printf " ${T_VALUE}(%s)${RESET}" "$account_sub"
  fi
  [ -n "$city" ] && printf " ${T_BORDER}${T_SEP}${RESET} ${T_HIGHLIGHT}%s${RESET}${T_BORDER},${RESET} ${T_ACCENT3}%s${RESET}" "$city" "$region_disp"
  [ -n "$temp_disp" ] && printf " ${T_BORDER}${T_SEP}${RESET} ${T_WEATHER}%s %s${RESET}" "$temp_disp" "$weather_desc"
  [ -n "$time_dur" ] && printf " ${T_BORDER}${T_SEP}${RESET} ${T_ACCENT1}Uptime:${RESET} ${T_VALUE}%s${RESET}" "$time_dur"
  printf "\n"

  # Lines 2-4: Session / Week / Context bars (one per line)
  local usage_5h_int="${usage_5h%%.*}"
  local usage_7d_int="${usage_7d%%.*}"
  usage_5h_int="${usage_5h_int:-0}"
  usage_7d_int="${usage_7d_int:-0}"

  # Icons are equal-width (all 2-col emoji) and labels padded to 8 chars so all
  # three bars start at the same column. Icons chosen to match each metric:
  #   ⏳ Session (5-hour rolling window)  📆 Week (7-day window)  🧠 Context (window fill)
  printf "${T_ACCENT2}⏳${RESET} ${T_ACCENT3}Session:${RESET} "
  build_bar "$usage_5h_int" 30 "$T_BAR_SESSION"
  printf " ${T_BAR_SESSION}${usage_5h_int}%%${RESET}"
  if [ -n "$reset_5h" ]; then
    local reset_5h_detail="${reset_5h}"
    [ -n "$reset_5h_abs" ] && reset_5h_detail="${reset_5h}, ${reset_5h_abs}"
    printf " ${T_ACCENT4}(${reset_5h_detail})${RESET}"
  fi
  printf "\n"

  printf "${T_ACCENT2}📆${RESET} ${T_ACCENT3}Week:   ${RESET} "
  build_bar "$usage_7d_int" 30 "$T_BAR_WEEK"
  printf " ${T_BAR_WEEK}${usage_7d_int}%%${RESET}"
  if [ -n "$reset_7d" ]; then
    local reset_7d_detail="${reset_7d}"
    [ -n "$reset_7d_abs" ] && reset_7d_detail="${reset_7d}, ${reset_7d_abs}"
    printf " ${T_ACCENT4}(${reset_7d_detail})${RESET}"
  fi
  printf "\n"

  printf "${T_ACCENT4}🧠${RESET} ${T_ACCENT4}Context:${RESET} "
  build_bar "$context_pct" 30 "$T_BAR_CTX"
  printf " ${T_BAR_CTX}${context_pct}%%${RESET} ${T_LABEL}(${context_k}k/${max_k}k)${RESET}"
  printf "\n"

  # Line 5: Session-time | Cost | Agents | CPU | Mem | Disk
  local sys_color_cpu sys_color_mem sys_color_disk
  sys_color_cpu=$(get_level_color "$(echo "$cpu_load" | awk '{printf "%.0f", $1 * 25}')" 2>/dev/null)
  sys_color_mem=$(get_level_color "$mem_used_pct")
  sys_color_disk=$(get_level_color "$disk_usage")

  # Line 5: CPU | Mem | Disk  (Agents:0 + Hunters count REMOVED 2026-06-02 —
  # Claude Code's native "(N local agents)" is the source of truth for live agents;
  # the dashboard Hunters field was redundant + disagreed with it, 12-min work-dir
  # window over-counted recently-finished hunters.)
  #
  # AUTH DOT REMOVED 2026-07-31. It reported on a state file belonging to a separate,
  # private toolchain and had no place in a general-purpose dashboard: this repo is
  # public, the hardcoded path disclosed that project's layout, and the panel was dead
  # weight for anyone not running it. It was also the only thing in this file coupled to
  # another project's directory structure, which is precisely how it broke silently —
  # that project reorganised, and the dot went on reporting a file nothing updated.
  [ -n "$T_ICON_SES" ] && printf "${T_ACCENT3}${T_ICON_SES}${RESET} "
  printf "${T_ACCENT3}CPU:${RESET} ${sys_color_cpu:-$T_VALUE}%s${RESET}" "$cpu_load"
  printf " ${T_BORDER}${T_SEP}${RESET} ${T_ACCENT3}Mem:${RESET} ${sys_color_mem:-$T_VALUE}%s${RESET}" "$mem_display"
  printf " ${T_BORDER}${T_SEP}${RESET} ${T_ACCENT3}Disk:${RESET} ${sys_color_disk:-$T_VALUE}%s${RESET}" "$disk_display"
  printf "\n"
}

# Buffer body, size the frame to the widest visible content line
body="$(render_body)"
box_w=$(disp_width "$body")
[ -z "$box_w" ] && box_w=0
box_w=$(( box_w + 1 ))                     # one column of breathing room
[ "$box_w" -lt 50 ] && box_w=50            # floor so the title rule isn't cramped
term_cap=$(( TERM_WIDTH - 1 ))
[ "$term_cap" -ge 50 ] && [ "$box_w" -gt "$term_cap" ] && box_w=$term_cap  # never exceed terminal

if [ "$THEME" = "cyberpunk" ]; then
  rule_top "$box_w"
  printf '%s\n' "$body"
  rule_bot "$box_w"
elif [ "$THEME" = "minimal" ]; then
  printf '%s\n' "$body"
else
  printf "${T_BORDER}━━━━ ${T_TITLE}${T_HEADER}${RESET} ${T_BORDER}"
  for ((i=0; i<58; i++)); do printf "━"; done
  printf "${RESET}\n"
  printf '%s\n' "$body"
  [ -n "$T_LINE_TOP" ] && make_line "$T_LINE_TOP"
fi

# A renderer must not leak a nonzero status: the last command in this script would otherwise
# decide it. `[ -n "$X" ] && ...` as a final statement exits 1 whenever X is empty, and a strict
# parent may treat that as failure and render nothing.
exit 0
