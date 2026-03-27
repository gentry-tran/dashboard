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
#    spider-verse, blade-runner, one-piece, ghibli
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

USAGE_CACHE_TTL=${DASHBOARD_USAGE_TTL:-120}       # 2 minutes
LOCATION_CACHE_TTL=${DASHBOARD_LOCATION_TTL:-3600} # 1 hour
WEATHER_CACHE_TTL=${DASHBOARD_WEATHER_TTL:-900}    # 15 minutes

# Context baseline: preloaded tokens not visible to hooks
CONTEXT_BASELINE=${DASHBOARD_CONTEXT_BASELINE:-22600}

# Theme (env var > CLI arg > config file > default)
THEME="${DASHBOARD_THEME:-cyberpunk}"

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
# TERMINAL WIDTH DETECTION
# ─────────────────────────────────────────────────────────────────────────────

detect_terminal_width() {
  local width=""
  if [ -n "$KITTY_WINDOW_ID" ] && command -v kitten >/dev/null 2>&1; then
    width=$(kitten @ ls 2>/dev/null | jq -r --argjson wid "$KITTY_WINDOW_ID" \
      '[.[] | .tabs[] | .windows[] | select(.id == $wid)] | .[0].columns // empty' 2>/dev/null)
  fi
  [ -z "$width" ] || [ "$width" = "0" ] && width=$(stty size </dev/tty 2>/dev/null | awk '{print $2}')
  [ -z "$width" ] || [ "$width" = "0" ] && width=$(tput cols 2>/dev/null)
  [ -z "$width" ] || [ "$width" = "0" ] && width=${COLUMNS:-80}
  echo "$width"
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

eval "$(echo "$input" | jq -r '
  "current_dir=" + (.workspace.current_dir // .cwd // "" | @sh) + "\n" +
  "model_name=" + (.model.display_name // "unknown" | @sh) + "\n" +
  "cc_version=" + (.version // "" | @sh) + "\n" +
  "duration_ms=" + (.cost.total_duration_ms // 0 | tostring) + "\n" +
  "cache_read=" + ((.context_window.current_usage.cache_read_input_tokens // 0) | tostring) + "\n" +
  "input_tokens=" + ((.context_window.current_usage.input_tokens // 0) | tostring) + "\n" +
  "cache_creation=" + ((.context_window.current_usage.cache_creation_input_tokens // 0) | tostring) + "\n" +
  "output_tokens=" + ((.context_window.current_usage.output_tokens // 0) | tostring) + "\n" +
  "context_max=" + (.context_window.context_window_size // 0 | tostring)
' 2>/dev/null)"

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

    *)
      echo "Unknown theme: $theme. Available: terminal-green, solarized, nord, cyberpunk, minimal, batman, iron-man, dbz, evangelion, ghost-in-shell, akira, spider-verse, blade-runner, one-piece, ghibli, rainforest, garden, terrarium, harvest" >&2
      THEME="cyberpunk"
      load_theme "cyberpunk"
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
  [ -f "$LOCATION_CACHE" ] && cache_age=$(($(date +%s) - $(stat -f %m "$LOCATION_CACHE" 2>/dev/null || stat -c %Y "$LOCATION_CACHE" 2>/dev/null || echo 0)))
  if [ "$cache_age" -gt "$LOCATION_CACHE_TTL" ]; then
    local loc_data=$(curl -s --max-time 3 "https://ipinfo.io/json" 2>/dev/null)
    if [ -n "$loc_data" ] && echo "$loc_data" | jq -e '.city' >/dev/null 2>&1; then
      echo "$loc_data" > "$LOCATION_CACHE"
    fi
  fi
}

# Weather (cached)
fetch_weather() {
  local cache_age=999999
  [ -f "$WEATHER_CACHE" ] && cache_age=$(($(date +%s) - $(stat -f %m "$WEATHER_CACHE" 2>/dev/null || stat -c %Y "$WEATHER_CACHE" 2>/dev/null || echo 0)))
  if [ "$cache_age" -gt "$WEATHER_CACHE_TTL" ]; then
    if [ -f "$LOCATION_CACHE" ]; then
      local loc=$(jq -r '.loc // empty' "$LOCATION_CACHE" 2>/dev/null)
      if [ -n "$loc" ]; then
        local lat="${loc%%,*}"
        local lon="${loc##*,}"
        local weather_data=$(curl -s --max-time 3 "https://api.open-meteo.com/v1/forecast?latitude=$lat&longitude=$lon&current=temperature_2m,weather_code&temperature_unit=celsius" 2>/dev/null)
        if [ -n "$weather_data" ] && echo "$weather_data" | jq -e '.current' >/dev/null 2>&1; then
          echo "$weather_data" > "$WEATHER_CACHE"
        fi
      fi
    fi
  fi
}

# Usage (cached, Anthropic API)
fetch_usage() {
  local cache_age=999999
  [ -f "$USAGE_CACHE" ] && cache_age=$(($(date +%s) - $(stat -f %m "$USAGE_CACHE" 2>/dev/null || stat -c %Y "$USAGE_CACHE" 2>/dev/null || echo 0)))
  if [ "$cache_age" -gt "$USAGE_CACHE_TTL" ]; then
    local creds=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
    local token=$(echo "$creds" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
    if [ -n "$token" ]; then
      local usage_data=$(curl -s --max-time 3 \
        -H "Authorization: Bearer $token" \
        -H "anthropic-beta: oauth-2025-04-20" \
        "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)
      if [ -n "$usage_data" ] && echo "$usage_data" | jq -e '.five_hour' >/dev/null 2>&1; then
        echo "$usage_data" > "$USAGE_CACHE"
      fi
    fi
  fi
}

# Fetch all data in background
fetch_location &
fetch_weather &
fetch_usage &
wait 2>/dev/null

# Parse location
city="" region="" timezone_name=""
if [ -f "$LOCATION_CACHE" ]; then
  city=$(jq -r '.city // empty' "$LOCATION_CACHE" 2>/dev/null)
  region=$(jq -r '.region // empty' "$LOCATION_CACHE" 2>/dev/null)
  timezone_name=$(jq -r '.timezone // empty' "$LOCATION_CACHE" 2>/dev/null)
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
if [ -n "$temp_c" ]; then
  temp_f=$(echo "$temp_c" | awk '{printf "%.1f", $1 * 9/5 + 32}')
fi

# Parse usage
usage_5h="" usage_7d="" reset_5h="" reset_7d=""
if [ -f "$USAGE_CACHE" ]; then
  usage_5h=$(jq -r '.five_hour.utilization // empty' "$USAGE_CACHE" 2>/dev/null)
  usage_7d=$(jq -r '.seven_day.utilization // empty' "$USAGE_CACHE" 2>/dev/null)
  usage_5h_reset=$(jq -r '.five_hour.resets_at // empty' "$USAGE_CACHE" 2>/dev/null)
  usage_7d_reset=$(jq -r '.seven_day.resets_at // empty' "$USAGE_CACHE" 2>/dev/null)
fi

# Format reset times
format_reset() {
  local reset_ts="$1"
  [ -z "$reset_ts" ] && return
  local reset_epoch
  # macOS
  reset_epoch=$(date -jf "%Y-%m-%dT%H:%M:%S" "${reset_ts%%.*}" "+%s" 2>/dev/null)
  # Linux fallback
  [ -z "$reset_epoch" ] && reset_epoch=$(date -d "${reset_ts}" "+%s" 2>/dev/null)
  [ -z "$reset_epoch" ] && return
  local now_epoch=$(date +%s)
  local diff=$(( reset_epoch - now_epoch ))
  [ "$diff" -lt 0 ] && diff=0
  local hours=$(( diff / 3600 ))
  local mins=$(( (diff % 3600) / 60 ))
  if [ "$hours" -gt 0 ]; then echo "${hours}h${mins}m"
  else echo "${mins}m"
  fi
}

reset_5h=$(format_reset "$usage_5h_reset")
reset_7d=$(format_reset "$usage_7d_reset")

# Format time with timezone
tz_abbr=$(date +%Z)
time_display=$(date +"%l:%M %p" | sed 's/^ //')
time_full="$time_display $tz_abbr"

# Skills count
skills_count=$(find "$CONFIG_DIR/skills" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')

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
  mem_display="${free_mem_mb}MB free"
else
  # Linux
  mem_display=$(free -m 2>/dev/null | awk '/^Mem:/ {printf "%dMB free", $7}')
  mem_used_pct=$(free 2>/dev/null | awk '/^Mem:/ {printf "%.0f", ($2-$7)*100/$2}')
fi
mem_used_pct="${mem_used_pct:-0}"
mem_display="${mem_display:-?}"

# Disk usage of cwd
disk_usage=$(df -h "${current_dir:-.}" 2>/dev/null | awk 'NR==2 {print $5}' | tr -d '%')
disk_display=$(df -h "${current_dir:-.}" 2>/dev/null | awk 'NR==2 {printf "%s/%s (%s)", $3, $2, $5}')
disk_usage="${disk_usage:-0}"
disk_display="${disk_display:-?}"

# Agent/task counts (from Claude Code task system if available)
# Count background agent processes
agent_count=$(ps aux 2>/dev/null | grep -c "[c]laude.*--agent" || echo "0")
agent_count="${agent_count:-0}"

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

# Context calculations
content_tokens=$((cache_read + input_tokens + cache_creation + output_tokens))
context_used=$((content_tokens + CONTEXT_BASELINE))

if [ "$context_max" -gt 0 ] && [ "$context_used" -gt 0 ]; then
  context_pct=$((context_used * 100 / context_max))
  context_k=$((context_used / 1000))
  max_k=$((context_max / 1000))
else
  context_pct=0; context_k=0; max_k=0
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
  local filled=$((pct * width / 100))
  [ "$filled" -gt "$width" ] && filled=$width
  local empty=$((width - filled))
  local bar=""
  for ((i=0; i<filled; i++)); do bar+="$T_BAR_FILL"; done
  local bar_empty=""
  for ((i=0; i<empty; i++)); do bar_empty+="$T_BAR_EMPTY"; done
  printf "${ctx_color}${bar}${T_DIM}${bar_empty}${RESET}"
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

# Line 1: Header
if [ "$THEME" = "cyberpunk" ]; then
  printf "${T_BORDER}╔══ ${T_TITLE}${T_HEADER}${RESET} ${T_BORDER}"
  for ((i=0; i<58; i++)); do printf "═"; done
  printf "╗${RESET}\n"
elif [ "$THEME" = "minimal" ]; then
  printf "${T_TITLE}${T_HEADER}${RESET}\n"
else
  printf "${T_BORDER}━━━━ ${T_TITLE}${T_HEADER}${RESET} ${T_BORDER}"
  for ((i=0; i<58; i++)); do printf "━"; done
  printf "${RESET}\n"
fi

# Line 2: Location + Time + Weather
# Colors: cyan labels, neon red city, cyan time value, neon red weather
location_str=""
[ -n "$city" ] && location_str="${T_ACCENT3}Location:${RESET} ${T_HIGHLIGHT}${city}${RESET}${T_BORDER},${RESET} ${T_ACCENT3}${region}${RESET}"
time_str="${T_ACCENT3}Time:${RESET} ${T_VALUE}${time_full}${RESET}"
weather_str=""
[ -n "$temp_c" ] && weather_str="${T_WEATHER}${temp_c}°C | ${temp_f}°F ${weather_desc}${RESET}"

if [ -n "$location_str" ]; then
  printf "${location_str} ${T_BORDER}${T_SEP}${RESET} ${time_str}"
  [ -n "$weather_str" ] && printf " ${T_BORDER}${T_SEP}${RESET} ${weather_str}"
  printf "\n"
else
  printf "${time_str}"
  [ -n "$weather_str" ] && printf " ${T_BORDER}${T_SEP}${RESET} ${weather_str}"
  printf "\n"
fi

# Line 3: Claude Code version + Model + Skills + MCP
# Colors: orange version, pink labels, green values
printf "${T_ACCENT2}Claude Code v${cc_version}${RESET} ${T_BORDER}${T_SEP}${RESET} "
printf "${T_ACCENT1}Model:${RESET} ${T_VALUE}${model_name}${RESET} ${T_BORDER}${T_SEP}${RESET} "
printf "${T_ACCENT1}Skills:${RESET} ${T_VALUE}${skills_count}${RESET} ${T_BORDER}${T_SEP}${RESET} "
printf "${T_ACCENT1}MCP:${RESET} ${T_VALUE}${mcp_count}${RESET}\n"

# Separator
if [ "$THEME" = "cyberpunk" ]; then
  printf "${T_BORDER}╠"
  for ((i=0; i<73; i++)); do printf "═"; done
  printf "╣${RESET}\n"
elif [ "$THEME" = "minimal" ]; then
  make_line "$T_LINE_H"
else
  make_line "$T_LINE_H"
fi

# Line 4: Context
[ -n "$T_ICON_CTX" ] && printf "${T_ACCENT4}${T_ICON_CTX}${RESET} "
printf "${T_ACCENT4}Context:${RESET} "
build_bar "$context_pct" 30
printf " ${ctx_color}${context_pct}%%${RESET} ${T_LABEL}(${context_k}k/${max_k}k)${RESET}"
printf " ${T_BORDER}${T_SEP}${RESET} "
[ -n "$T_ICON_TIME" ] && printf "${T_ACCENT3}${T_ICON_TIME}${RESET} "
printf "${T_VALUE}${time_dur}${RESET}\n"

# Line 5: Usage
usage_5h_int="${usage_5h%%.*}"
usage_7d_int="${usage_7d%%.*}"
usage_5h_int="${usage_5h_int:-0}"
usage_7d_int="${usage_7d_int:-0}"

# Colors: orange icon+label, cyan sub-labels, green values
[ -n "$T_ICON_USE" ] && printf "${T_ACCENT2}${T_ICON_USE}${RESET} "
printf "${T_ACCENT2}Usage:${RESET}   ${T_ACCENT3}Session:${RESET} ${u5h_color}${usage_5h_int}%%${RESET}"
[ -n "$reset_5h" ] && printf " ${T_ACCENT4}(${reset_5h})${RESET}"
printf " ${T_BORDER}${T_SEP}${RESET} ${T_ACCENT3}Week:${RESET} ${u7d_color}${usage_7d_int}%%${RESET}"
[ -n "$reset_7d" ] && printf " ${T_ACCENT4}(${reset_7d})${RESET}"
printf "\n"

# Line 6: Session — duration, turns, cost, agents
# Colors: cyan icon+label, pink sub-labels, green values
[ -n "$T_ICON_SES" ] && printf "${T_ACCENT3}${T_ICON_SES}${RESET} "
printf "${T_ACCENT3}Session:${RESET} ${T_VALUE}${time_dur}${RESET}"
[ "$turn_count" != "?" ] && printf " ${T_BORDER}${T_SEP}${RESET} ${T_ACCENT1}Turns:${RESET} ${T_VALUE}${turn_count}${RESET}"
[ -n "$cost_display" ] && printf " ${T_BORDER}${T_SEP}${RESET} ${T_ACCENT1}Cost:${RESET} ${T_VALUE}${cost_display}${RESET}"
if [ "$agent_count" -gt 0 ] 2>/dev/null; then
  printf " ${T_BORDER}${T_SEP}${RESET} ${T_LABEL}Agents:${RESET} ${T_GREEN}${agent_count} active${RESET}"
fi
printf "\n"

# Line 7: System — CPU, memory, disk
sys_color_cpu=$(get_level_color "$(echo "$cpu_load" | awk '{printf "%.0f", $1 * 25}')" 2>/dev/null)
sys_color_mem=$(get_level_color "$mem_used_pct")
sys_color_disk=$(get_level_color "$disk_usage")

# Colors: orange System: label, cyan sub-labels, red values
printf "${T_ACCENT2}System:${RESET}  "
printf "${T_ACCENT3}CPU:${RESET} ${sys_color_cpu:-$T_VALUE}${cpu_load}${RESET}"
printf " ${T_BORDER}${T_SEP}${RESET} ${T_ACCENT3}Mem:${RESET} ${sys_color_mem:-$T_VALUE}${mem_display}${RESET}"
printf " ${T_BORDER}${T_SEP}${RESET} ${T_ACCENT3}Disk:${RESET} ${sys_color_disk:-$T_VALUE}${disk_display}${RESET}"
printf "\n"

# Footer
if [ "$THEME" = "cyberpunk" ]; then
  printf "${T_BORDER}╚"
  for ((i=0; i<73; i++)); do printf "═"; done
  printf "╝${RESET}\n"
elif [ "$THEME" != "minimal" ]; then
  if [ -n "$T_LINE_TOP" ]; then
    make_line "$T_LINE_TOP"
  fi
fi
