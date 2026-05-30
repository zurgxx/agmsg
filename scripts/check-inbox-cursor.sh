#!/usr/bin/env bash
set -euo pipefail

# Cursor CLI stop-hook wrapper. Returns followup_message JSON or {}.
# Usage: check-inbox-cursor.sh <project_path>
#
# stdin: Cursor hook JSON (read once; never logged — may contain user_email).
# Phase 1: single identity per (project, cursor) only; multiple identities return {}.

PROJECT="${1:?Usage: check-inbox-cursor.sh <project_path>}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TYPE="cursor"

sql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }

cursor_normalize_project() {
  local project="$1"
  if [ -d "$project" ]; then
    (cd "$project" && pwd -P)
  elif [ -f "$project" ]; then
    local dir base
    dir=$(cd "$(dirname "$project")" && pwd -P)
    base=$(basename "$project")
    printf '%s/%s' "$dir" "$base"
  elif command -v realpath >/dev/null 2>&1; then
    realpath -m "$project" 2>/dev/null || printf '%s' "$project"
  else
    printf '%s' "$project"
  fi
}

emit_empty() {
  echo '{}'
}

emit_followup() {
  local body="$1"
  local tmp tmp_esc
  tmp=$(mktemp)
  printf '%s' "$body" > "$tmp"
  tmp_esc=$(sql_escape "$tmp")
  sqlite3 :memory: "SELECT json_object('followup_message', cast(readfile('$tmp_esc') as text));"
  rm -f "$tmp"
}

# Read hook stdin once (do not log).
INPUT=$(cat 2>/dev/null || true)

# loop_count guard — avoid infinite follow-up turns.
LOOP_LIMIT=$("$SCRIPT_DIR/config.sh" get delivery.cursor.loop_limit 1)
case "$LOOP_LIMIT" in ''|*[!0-9]*) LOOP_LIMIT=1 ;; esac
if [ -n "$INPUT" ]; then
  INPUT_ESC=$(sql_escape "$INPUT")
  LOOP_COUNT=$(sqlite3 :memory: "
    SELECT COALESCE(json_extract('$INPUT_ESC', '\$.loop_count'), -1);
  " 2>/dev/null || echo -1)
  case "$LOOP_COUNT" in ''|*[!0-9-]*) LOOP_COUNT=-1 ;; esac
  if [ "$LOOP_COUNT" -ge 0 ] && [ "$LOOP_COUNT" -ge "$LOOP_LIMIT" ]; then
    emit_empty
    exit 0
  fi
fi

PROJECT=$(cursor_normalize_project "$PROJECT")

# Identify agent and teams
WHOAMI=$("$SCRIPT_DIR/whoami.sh" "$PROJECT" "$TYPE")
if echo "$WHOAMI" | grep -q "not_joined=true"; then
  emit_empty
  exit 0
fi

if echo "$WHOAMI" | grep -q "multiple=true"; then
  emit_empty
  exit 0
fi

AGENT=$(echo "$WHOAMI" | sed -n 's/.*agent=\([^ ]*\).*/\1/p')
TEAMS=$(echo "$WHOAMI" | sed -n 's/.*teams=\([^ ]*\).*/\1/p')

if [ -z "$AGENT" ] || [ -z "$TEAMS" ]; then
  emit_empty
  exit 0
fi

# Cooldown
MARKER="$SKILL_DIR/db/.lastcheck-$AGENT"
if [ -f "$MARKER" ]; then
  if [ "$(uname)" = "Darwin" ]; then
    last=$(stat -f %m "$MARKER")
  else
    last=$(stat -c %Y "$MARKER")
  fi
  now=$(date +%s)
  INTERVAL=$("$SCRIPT_DIR/config.sh" get delivery.turn.check_interval "")
  [ -z "$INTERVAL" ] && INTERVAL=$("$SCRIPT_DIR/config.sh" get hook.check_interval 60)
  case "$INTERVAL" in ''|*[!0-9]*) INTERVAL=60 ;; esac
  if [ $(( now - last )) -lt "$INTERVAL" ]; then
    emit_empty
    exit 0
  fi
fi

touch "$MARKER"

DB="$SKILL_DIR/db/messages.db"
if [ ! -f "$DB" ]; then
  emit_empty
  exit 0
fi

AGENT_ESC=$(sql_escape "$AGENT")
OUTPUT=""
IFS=',' read -ra TEAM_LIST <<< "$TEAMS"
for team in "${TEAM_LIST[@]}"; do
  TEAM_ESC=$(sql_escape "$team")
  RESULT=$(sqlite3 -separator $'\x1f' "$DB" "
    SELECT from_agent || char(31) || replace(replace(body, char(10), '\n'), char(9), '\t') || char(31) || created_at
    FROM messages
    WHERE team='$TEAM_ESC' AND to_agent='$AGENT_ESC' AND read_at IS NULL
    ORDER BY created_at ASC;
  " 2>/dev/null || true)
  if [ -n "$RESULT" ]; then
    COUNT=$(echo "$RESULT" | wc -l | tr -d ' ')
    OUTPUT+="$COUNT new in $team:"$'\n'
    while IFS=$'\x1f' read -r from body ts; do
      OUTPUT+="  [$ts] $from: $body"$'\n'
    done <<< "$RESULT"
    sqlite3 "$DB" "
      UPDATE messages SET read_at=strftime('%Y-%m-%dT%H:%M:%SZ','now')
      WHERE team='$TEAM_ESC' AND to_agent='$AGENT_ESC' AND read_at IS NULL;
    " 2>/dev/null || true
  fi
done

if [ -z "$OUTPUT" ]; then
  emit_empty
  exit 0
fi

MSG="agmsg has unread messages. Read them and respond if needed:"$'\n'"$OUTPUT"
emit_followup "$MSG"
