#!/usr/bin/env bash
# usage-history-logger.sh — append a timestamped snapshot of the Anthropic OAuth
# usage windows to a JSONL history, and LOUDLY flag any window that resets BEFORE
# its previously-reported resets_at (an early/anomalous reset).
#
# WHY (2026-06-09): "did my weekly tokens reset early?" was UNANSWERABLE because
# nothing logged usage over time — only a single ever-overwritten cache snapshot
# existed. This logs every poll so a reset (scheduled OR early) is timestamped and
# provable, and an early reset is auto-detected for an Anthropic support report.
#
# Reset detection: a window "reset" when its resets_at CHANGES (rolls forward) or
# its utilization drops sharply. If the reset is observed at a wall-clock time
# EARLIER than the window's own previously-reported resets_at, it is EARLY.
#
# Source: same endpoint the dashboard uses (api.anthropic.com/api/oauth/usage),
# OAuth token from Keychain. Token used in-memory only — never written to disk.
#
# Usage: usage-history-logger.sh        # poll + append + detect (cron-friendly)
#        usage-history-logger.sh --tail # show recent history + any early-reset flags
set -uo pipefail

CACHE_DIR="${DASHBOARD_CACHE_DIR:-$HOME/.claude/dashboard-cache}"
HIST="$CACHE_DIR/usage-history.jsonl"
ALERTS="$CACHE_DIR/usage-reset-alerts.log"
mkdir -p "$CACHE_DIR"

if [ "${1:-}" = "--tail" ]; then
  echo "=== last 15 usage snapshots ==="; tail -15 "$HIST" 2>/dev/null
  echo "=== reset alerts ==="; cat "$ALERTS" 2>/dev/null || echo "(none)"
  exit 0
fi

NOW_EPOCH=$(date +%s)
NOW_ISO=$(date -u +%FT%TZ)

# ISO8601 → epoch, truncating fractional seconds (the API jitters the sub-second
# part of resets_at every call, so compare at whole-second granularity only).
iso2epoch() {
  local clean
  clean=$(printf '%s' "$1" | sed 's/\.[0-9]*//;s/+00:00//;s/Z//')
  TZ=UTC date -jf "%Y-%m-%dT%H:%M:%S" "$clean" "+%s" 2>/dev/null \
    || date -u -d "$clean" "+%s" 2>/dev/null || echo 0
}

# Fetch live usage (same call as dashboard.sh fetch_usage).
CREDS=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
TOKEN=$(printf '%s' "$CREDS" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
[ -n "$TOKEN" ] || { echo "[$NOW_ISO] no oauth token in keychain — skip" >&2; exit 0; }

USAGE=$(curl -s --max-time 5 \
  -H "Authorization: Bearer $TOKEN" \
  -H "anthropic-beta: oauth-2025-04-20" \
  "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)
echo "$USAGE" | jq -e '.five_hour' >/dev/null 2>&1 || { echo "[$NOW_ISO] usage fetch failed — skip" >&2; exit 0; }

# Build this snapshot line.
LINE=$(printf '%s' "$USAGE" | jq -c --arg ts "$NOW_ISO" '{
  ts: $ts,
  five_hour:  {util: .five_hour.utilization,  resets_at: .five_hour.resets_at},
  seven_day:  {util: .seven_day.utilization,  resets_at: .seven_day.resets_at}
}')

# Compare against the previous snapshot to detect resets.
PREV=$(tail -1 "$HIST" 2>/dev/null)
echo "$LINE" >> "$HIST"

[ -z "$PREV" ] && exit 0
for W in five_hour seven_day; do
  P_RESET=$(printf '%s' "$PREV" | jq -r ".$W.resets_at // empty")
  C_RESET=$(printf '%s' "$LINE" | jq -r ".$W.resets_at // empty")
  P_UTIL=$(printf '%s' "$PREV" | jq -r ".$W.util // 0")
  C_UTIL=$(printf '%s' "$LINE" | jq -r ".$W.util // 0")
  [ -z "$P_RESET" ] || [ -z "$C_RESET" ] && continue

  # A reset = resets_at rolled forward by >2min (ignore sub-second API jitter) OR
  # utilization dropped >20 points.
  P_RESET_EPOCH=$(iso2epoch "$P_RESET")
  C_RESET_EPOCH=$(iso2epoch "$C_RESET")
  DELTA=$(( C_RESET_EPOCH > P_RESET_EPOCH ? C_RESET_EPOCH - P_RESET_EPOCH : P_RESET_EPOCH - C_RESET_EPOCH ))
  ROLLED=$([ "$DELTA" -gt 120 ] && echo 1 || echo 0)
  DROP=$(awk -v p="$P_UTIL" -v c="$C_UTIL" 'BEGIN{print (p-c>20)?1:0}')
  [ "$ROLLED" -eq 1 ] || [ "$DROP" -eq 1 ] || continue

  # Was it EARLY? i.e. observed now, but the window's PRIOR resets_at is still in
  # the future → the window rolled before its own scheduled reset.
  if [ "$P_RESET_EPOCH" -gt "$NOW_EPOCH" ]; then
    MINS_EARLY=$(( (P_RESET_EPOCH - NOW_EPOCH) / 60 ))
    MSG="[$NOW_ISO] ⚠ EARLY RESET: $W rolled NOW but its prior resets_at=$P_RESET was ${MINS_EARLY}min in the FUTURE (util $P_UTIL%→$C_UTIL%). New resets_at=$C_RESET. Report to Anthropic with this line."
    echo "$MSG" | tee -a "$ALERTS"
  else
    echo "[$NOW_ISO] ok: $W reset on/after schedule (prior resets_at=$P_RESET, util $P_UTIL%→$C_UTIL%, new=$C_RESET)" >> "$ALERTS"
  fi
done
