#!/usr/bin/env bash
set -euo pipefail

# Manage how incoming messages reach this agent.
#
# Usage:
#   delivery.sh set <mode> <type> <project_path>
#   delivery.sh status [<type> <project_path>]
#   delivery.sh stop
#   delivery.sh restart [<project_path> <type>]
#
# Modes:
#   monitor  — SessionStart hook → Claude Code Monitor tool → watch.sh stream
#   turn     — Stop hook → check-inbox.sh between turns (legacy)
#   both     — monitor primary; turn as per-session safety net
#   off      — no automatic delivery
#
# settings.json injection is idempotent: each `set` call first strips any
# existing agmsg-owned SessionStart/Stop entries, then re-adds whichever
# the new mode requires. Re-running with the same mode is a no-op.
#
# For in-session activation, several actions print a final
# "AGMSG-DIRECTIVE:" line that a running Claude Code agent reads from the
# command output and acts on (invoke Monitor, TaskStop the watcher). This
# closes the gap where, without the directive, only the *next* session
# would pick up the mode change.

ACTION="${1:?Usage: delivery.sh set|status|restart ...}"
shift

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL_NAME="$(basename "$SKILL_DIR")"
RUN_DIR="$SKILL_DIR/run"
CURSOR_RULE_MARKER="<!-- agmsg:managed file=agmsg.mdc -->"

resolve_hooks_file() {
  local type="$1"
  local project="$2"
  case "$type" in
    claude-code) echo "$project/.claude/settings.local.json" ;;
    codex)       echo "$project/.codex/hooks.json" ;;
    cursor)      echo "$project/.cursor/hooks.json" ;;
    gemini|antigravity) echo "$project/.agent/rules/agmsg.md" ;;
    copilot)     echo "$project/.github/hooks/agmsg.json" ;;
    *) echo "Unknown agent type: $type" >&2; return 1 ;;
  esac
}

posix_shell_quote() {
  local s="$1"
  printf "'%s'" "$(printf '%s' "$s" | sed "s/'/'\\\\''/g")"
}

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

cursor_expected_command() {
  local project="$1"
  project=$(cursor_normalize_project "$project")
  printf '%s %s' \
    "$(posix_shell_quote "$SKILL_DIR/scripts/check-inbox-cursor.sh")" \
    "$(posix_shell_quote "$project")"
}

cursor_rule_file() {
  local project="$1"
  printf '%s/.cursor/rules/agmsg.mdc' "$project"
}

sed_replacement_escape() {
  printf '%s' "$1" | sed 's/[\/&\\]/\\&/g'
}

write_cursor_rule() {
  local project="$1"
  local rule_file template skill_name_esc tmp
  rule_file=$(cursor_rule_file "$project")
  template="$SKILL_DIR/templates/cursor-rule.mdc"

  if [ -f "$rule_file" ] && ! grep -Fq "$CURSOR_RULE_MARKER" "$rule_file"; then
    echo "Warning: $rule_file exists without agmsg marker; leaving it unchanged" >&2
    return 0
  fi

  if [ ! -f "$template" ]; then
    echo "Error: Cursor rule template not found: $template" >&2
    return 1
  fi

  mkdir -p "$(dirname "$rule_file")"
  tmp="$(mktemp "$(dirname "$rule_file")/.agmsg.mdc.XXXXXX")"
  skill_name_esc=$(sed_replacement_escape "$SKILL_NAME")
  sed "s/__SKILL_NAME__/$skill_name_esc/g" "$template" > "$tmp"
  mv "$tmp" "$rule_file"
}

sql_path_escape() {
  printf '%s' "$1" | sed "s/'/''/g"
}

cursor_json_valid() {
  local file="$1"
  [ ! -f "$file" ] && return 0
  local file_esc
  file_esc=$(printf '%s' "$file" | sed "s/'/''/g")
  [ "$(sqlite3 :memory: "SELECT json_valid(readfile('$file_esc'));" 2>/dev/null || echo 0)" = "1" ]
}

# Remove agmsg Cursor stop hooks (exact command match only).
# Entries with missing/null command or a different command are always kept.
strip_agmsg_cursor_stop() {
  local settings_esc="$1"
  local expected_cmd_file_esc="$2"

  sqlite3 :memory: "
    SELECT CASE
      WHEN json_extract('$settings_esc', '\$.hooks.stop') IS NULL THEN
        '$settings_esc'
      WHEN json_type(json_extract('$settings_esc', '\$.hooks.stop')) != 'array' THEN
        '$settings_esc'
      WHEN (SELECT count(*) FROM json_each(json_extract('$settings_esc', '\$.hooks.stop')) AS h
            WHERE json_extract(h.value, '\$.command') = cast(readfile('$expected_cmd_file_esc') as text)) = 0 THEN
        '$settings_esc'
      ELSE
        json_set('$settings_esc', '\$.hooks.stop',
          (SELECT json_group_array(json(h.value))
           FROM json_each(json_extract('$settings_esc', '\$.hooks.stop')) AS h
           WHERE json_extract(h.value, '\$.command') IS NULL
              OR json_extract(h.value, '\$.command') != cast(readfile('$expected_cmd_file_esc') as text)))
    END;
  "
}

add_cursor_stop_hook() {
  local settings_esc="$1"
  local expected_cmd_file_esc="$2"
  local entry_json entry_esc

  entry_json=$(sqlite3 :memory: "
    SELECT json_object('command', cast(readfile('$expected_cmd_file_esc') as text), 'loop_limit', 1);
  ")
  entry_esc=$(printf '%s' "$entry_json" | sed "s/'/''/g")

  sqlite3 :memory: "
    WITH base AS (
      SELECT CASE
        WHEN json_extract('$settings_esc', '\$.hooks') IS NULL
        THEN json_set('$settings_esc', '\$.hooks', json('{}'))
        ELSE '$settings_esc'
      END AS s
    )
    SELECT CASE
      WHEN json_extract(s, '\$.hooks.stop') IS NOT NULL
       AND json_type(json_extract(s, '\$.hooks.stop')) != 'array' THEN
        s
      WHEN EXISTS (
        SELECT 1 FROM json_each(json_extract(s, '\$.hooks.stop')) AS h
        WHERE json_extract(h.value, '\$.command') = cast(readfile('$expected_cmd_file_esc') as text)
      ) THEN s
      WHEN json_extract(s, '\$.hooks.stop') IS NULL THEN
        json_set(s, '\$.hooks.stop', json_array(json('$entry_esc')))
      ELSE
        json_set(s, '\$.hooks.stop',
          (SELECT json_group_array(json(v.value)) FROM (
             SELECT value FROM json_each(json_extract(s, '\$.hooks.stop'))
             UNION ALL
             SELECT '$entry_esc'
           ) v)
        )
    END
    FROM base;
  "
}

prune_empty_cursor_hooks() {
  local s="$1"
  sqlite3 :memory: "
    WITH step1 AS (
      SELECT CASE
        WHEN json_extract('$s', '\$.hooks.stop') IS NOT NULL
         AND json_type(json_extract('$s', '\$.hooks.stop')) = 'array'
         AND json_array_length(json_extract('$s', '\$.hooks.stop')) = 0 THEN
          json_remove('$s', '\$.hooks.stop')
        ELSE '$s'
      END AS s1
    )
    SELECT CASE
      WHEN json_extract(s1, '\$.hooks') IS NOT NULL
       AND json_type(json_extract(s1, '\$.hooks')) = 'object'
       AND (SELECT count(*) FROM json_each(json_extract(s1, '\$.hooks'))) = 0 THEN
        json_remove(s1, '\$.hooks')
      ELSE s1
    END FROM step1;
  "
}

apply_settings_cursor() {
  local project="$1"
  local mode="$2"
  local hooks_file
  hooks_file=$(resolve_hooks_file "cursor" "$project")

  case "$mode" in
    monitor|both)
      echo "Cursor CLI does not support delivery mode '$mode' (supported: turn, off)" >&2
      return 1
      ;;
    turn|off) ;;
    *)
      echo "Unknown mode: $mode (use turn|off)" >&2
      return 1
      ;;
  esac

  mkdir -p "$(dirname "$hooks_file")"

  if [ -f "$hooks_file" ] && ! cursor_json_valid "$hooks_file"; then
    echo "Error: $hooks_file is not valid JSON; refusing to modify" >&2
    return 1
  fi

  local settings_esc expected_cmd expected_cmd_esc hooks_file_esc
  hooks_file_esc=$(sql_path_escape "$hooks_file")
  if [ -f "$hooks_file" ]; then
    settings_esc=$(read_settings_escaped "$hooks_file")
    if [ "$(sqlite3 :memory: "
      SELECT CASE
        WHEN json_type(readfile('$hooks_file_esc'), '\$.hooks') IS NOT NULL
         AND json_type(readfile('$hooks_file_esc'), '\$.hooks') != 'object'
        THEN 1 ELSE 0 END;
    " 2>/dev/null || echo 0)" = "1" ]; then
      echo "Error: $hooks_file hooks must be a JSON object; refusing to modify" >&2
      return 1
    fi
    if [ "$(sqlite3 :memory: "
      SELECT CASE
        WHEN json_type(readfile('$hooks_file_esc'), '\$.hooks.stop') IS NOT NULL
         AND json_type(readfile('$hooks_file_esc'), '\$.hooks.stop') != 'array'
        THEN 1 ELSE 0 END;
    " 2>/dev/null || echo 0)" = "1" ]; then
      echo "Error: $hooks_file hooks.stop must be a JSON array; refusing to modify" >&2
      return 1
    fi
  else
    settings_esc='{"version":1,"hooks":{}}'
  fi

  if [ "$mode" = "turn" ]; then
    write_cursor_rule "$project" || return 1
  fi

  expected_cmd=$(cursor_expected_command "$project")
  local expected_tmp expected_tmp_esc
  expected_tmp=$(mktemp)
  printf '%s' "$expected_cmd" > "$expected_tmp"
  expected_tmp_esc=$(sql_path_escape "$expected_tmp")

  settings_esc=$(strip_agmsg_cursor_stop "$settings_esc" "$expected_tmp_esc" | sed "s/'/''/g")

  if [ "$mode" = "turn" ]; then
    settings_esc=$(add_cursor_stop_hook "$settings_esc" "$expected_tmp_esc" | sed "s/'/''/g")
  fi

  rm -f "$expected_tmp"

  settings_esc=$(prune_empty_cursor_hooks "$settings_esc" | sed "s/'/''/g")
  settings_esc=$(sqlite3 :memory: "
    SELECT CASE
      WHEN json_extract('$settings_esc', '\$.version') IS NULL
      THEN json_set('$settings_esc', '\$.version', 1)
      ELSE '$settings_esc'
    END;
  " | sed "s/'/''/g")

  local unescaped tmp
  unescaped=$(printf '%s' "$settings_esc" | sed "s/''/'/g")
  if [ "$(sqlite3 :memory: "SELECT json_valid('$settings_esc');")" != "1" ]; then
    echo "Error: internal error generating $hooks_file (invalid JSON)" >&2
    return 1
  fi

  tmp="$(mktemp "$(dirname "$hooks_file")/.hooks.json.XXXXXX")"
  printf '%s' "$unescaped" > "$tmp"
  if ! cursor_json_valid "$tmp"; then
    rm -f "$tmp"
    echo "Error: internal error generating $hooks_file (invalid JSON)" >&2
    return 1
  fi
  mv "$tmp" "$hooks_file"
}

read_settings_escaped() {
  if [ -f "$1" ]; then
    sed "s/'/''/g" "$1"
  else
    echo '{}'
  fi
}

# Strip any agmsg-owned hook entries from <event> in settings JSON. An entry
# is "agmsg-owned" when one of its inner hooks references a path under our
# skill directory. Result: the entire <event> array minus those entries
# (or .hooks.<event> deleted if the array becomes empty).
strip_agmsg_event() {
  local settings_esc="$1"
  local event="$2"

  sqlite3 :memory: "
    SELECT CASE
      WHEN json_extract('$settings_esc', '\$.hooks.$event') IS NULL THEN
        '$settings_esc'
      WHEN (SELECT count(*) FROM json_each(json_extract('$settings_esc', '\$.hooks.$event')) AS s
            WHERE NOT EXISTS (
              SELECT 1 FROM json_each(json_extract(s.value, '\$.hooks')) AS h
              WHERE instr(json_extract(h.value, '\$.command'), '$SKILL_NAME') > 0
            )) = 0 THEN
        json_remove('$settings_esc', '\$.hooks.$event')
      ELSE
        json_set('$settings_esc', '\$.hooks.$event',
          (SELECT json_group_array(json(s.value))
           FROM json_each(json_extract('$settings_esc', '\$.hooks.$event')) AS s
           WHERE NOT EXISTS (
             SELECT 1 FROM json_each(json_extract(s.value, '\$.hooks')) AS h
             WHERE instr(json_extract(h.value, '\$.command'), '$SKILL_NAME') > 0
           ))
        )
    END;
  "
}

# Wrap a POSIX shell command so Codex's Windows runner executes it through Git
# Bash. On native Windows, Codex runs each hook command via PowerShell, which
# cannot execute a bare POSIX ".sh" path, so the hook exits non-zero. Codex hook
# config supports a "commandWindows" key that takes precedence on Windows; the
# "& '<bash.exe>' -lc \"...\"" form is what Codex itself emits for shell calls.
windows_wrap() {
  local posix_cmd="$1"
  printf "& 'C:\\\\Program Files\\\\Git\\\\bin\\\\bash.exe' -lc \"%s\"" "$posix_cmd"
}

# Append a single entry of the form {"matcher":"","hooks":[{"type":"command","command":"<cmd>"}]}
# to .hooks.<event>, creating arrays/objects as needed. For Codex agents (pass
# "codex" as the 4th arg) the entry also carries a "commandWindows" so the hook
# runs on native Windows; other agent types are unchanged.
add_event_entry() {
  local settings_esc="$1"
  local event="$2"
  local cmd="$3"
  local hook_type="${4:-}"

  local hook_inner="\"type\":\"command\",\"command\":\"$cmd\""
  if [ "$hook_type" = "codex" ]; then
    local cw; cw=$(windows_wrap "$cmd")
    cw="${cw//\\/\\\\}"; cw="${cw//\"/\\\"}"
    hook_inner="$hook_inner,\"commandWindows\":\"$cw\""
  fi
  local entry="{\"matcher\":\"\",\"hooks\":[{$hook_inner}]}"
  local entry_esc
  entry_esc=$(printf '%s' "$entry" | sed "s/'/''/g")

  sqlite3 :memory: "
    WITH base AS (
      SELECT CASE WHEN json_extract('$settings_esc', '\$.hooks') IS NULL
                  THEN json_set('$settings_esc', '\$.hooks', json('{}'))
                  ELSE '$settings_esc' END AS s
    )
    SELECT CASE
      WHEN json_extract(s, '\$.hooks.$event') IS NULL THEN
        json_set(s, '\$.hooks.$event', json_array(json('$entry_esc')))
      ELSE
        json_set(s, '\$.hooks.$event',
          (SELECT json_group_array(json(v.value)) FROM (
             SELECT value FROM json_each(json_extract(s, '\$.hooks.$event'))
             UNION ALL
             SELECT '$entry_esc'
           ) v)
        )
    END
    FROM base;
  "
}

# Drop the entire .hooks object if it ended up empty after stripping.
prune_empty_hooks() {
  local s="$1"
  sqlite3 :memory: "
    SELECT CASE
      WHEN json_extract('$s', '\$.hooks') IS NULL THEN '$s'
      WHEN (SELECT count(*) FROM json_each(json_extract('$s', '\$.hooks'))) = 0 THEN
        json_remove('$s', '\$.hooks')
      ELSE '$s'
    END;
  "
}

apply_settings_copilot() {
  local type="$1"
  local project="$2"
  local mode="$3"
  local hooks_file
  hooks_file=$(resolve_hooks_file "$type" "$project")

  # Validate the mode BEFORE touching any existing file. Rejecting
  # monitor/both must not destroy a working turn hook.
  case "$mode" in
    turn|off) ;;
    monitor|both)
      echo "Error: '$mode' mode is not supported for $type (no Monitor-tool equivalent). Use 'turn' or 'off'." >&2
      return 1
      ;;
    *)
      echo "Unknown mode: $mode (use turn|off)" >&2
      return 1
      ;;
  esac

  # Strip first so re-applying turn is an idempotent rewrite and turn->off
  # cleanly removes the file.
  rm -f "$hooks_file"

  if [ "$mode" = "turn" ]; then
    mkdir -p "$(dirname "$hooks_file")"
    local cmd="'$SKILL_DIR/scripts/check-inbox.sh' '$type' '$project'"
    # json_quote handles JSON-string escaping for arbitrary command strings
    # (project paths may contain JSON-special chars).
    local cmd_json
    cmd_json=$(sqlite3 :memory: "SELECT json_quote('$(printf '%s' "$cmd" | sed "s/'/''/g")');")
    # Use PascalCase 'Stop' trigger so the input payload field names match
    # the snake_case form (session_id) that check-inbox.sh already parses.
    cat <<EOF > "$hooks_file"
{
  "version": 1,
  "hooks": {
    "Stop": [
      {
        "type": "command",
        "bash": $cmd_json,
        "timeoutSec": 30
      }
    ]
  }
}
EOF
  fi
}

apply_settings_gemini() {
  local type="$1"
  local project="$2"
  local mode="$3"
  local rule_file
  rule_file=$(resolve_hooks_file "$type" "$project")

  # Remove existing rule file
  rm -f "$rule_file"

  case "$mode" in
    turn|both)
      mkdir -p "$(dirname "$rule_file")"
      cat <<EOF > "$rule_file"
# agmsg Integration Rule

## PostToolUse
After each tool call, automatically check the agmsg inbox for unread messages.
- Command: '$SKILL_DIR/scripts/check-inbox.sh' '$type' '$project'
EOF
      ;;
    monitor)
      echo "Warning: 'monitor' mode is not fully supported for $type yet. Using turn-based hook." >&2
      apply_settings_gemini "$type" "$project" "turn"
      ;;
    off)
      ;;
  esac
}

apply_settings() {
  local type="$1"
  local project="$2"
  local mode="$3"

  if [ "$type" = "cursor" ]; then
    apply_settings_cursor "$project" "$mode"
    return
  fi

  if [ "$type" = "gemini" ] || [ "$type" = "antigravity" ]; then
    apply_settings_gemini "$type" "$project" "$mode"
    return
  fi

  if [ "$type" = "copilot" ]; then
    apply_settings_copilot "$type" "$project" "$mode"
    return
  fi

  local hooks_file
  hooks_file=$(resolve_hooks_file "$type" "$project")
  mkdir -p "$(dirname "$hooks_file")"

  local settings_esc
  settings_esc=$(read_settings_escaped "$hooks_file")

  # 1) Strip any prior agmsg ownership from SessionStart, SessionEnd, Stop.
  settings_esc=$(strip_agmsg_event "$settings_esc" "SessionStart" | sed "s/'/''/g")
  settings_esc=$(strip_agmsg_event "$settings_esc" "SessionEnd"   | sed "s/'/''/g")
  settings_esc=$(strip_agmsg_event "$settings_esc" "Stop"         | sed "s/'/''/g")

  # 2) Re-add what this mode wants.
  case "$mode" in
    monitor)
      local ss="'$SKILL_DIR/scripts/session-start.sh' '$type' '$project'"
      local se="'$SKILL_DIR/scripts/session-end.sh'   '$type' '$project'"
      settings_esc=$(add_event_entry "$settings_esc" "SessionStart" "$ss" "$type" | sed "s/'/''/g")
      settings_esc=$(add_event_entry "$settings_esc" "SessionEnd"   "$se" "$type" | sed "s/'/''/g")
      ;;
    turn)
      local cmd="'$SKILL_DIR/scripts/check-inbox.sh' '$type' '$project'"
      settings_esc=$(add_event_entry "$settings_esc" "Stop" "$cmd" "$type" | sed "s/'/''/g")
      ;;
    both)
      local ss="'$SKILL_DIR/scripts/session-start.sh' '$type' '$project'"
      local se="'$SKILL_DIR/scripts/session-end.sh'   '$type' '$project'"
      local st="'$SKILL_DIR/scripts/check-inbox.sh'   '$type' '$project'"
      settings_esc=$(add_event_entry "$settings_esc" "SessionStart" "$ss" "$type" | sed "s/'/''/g")
      settings_esc=$(add_event_entry "$settings_esc" "SessionEnd"   "$se" "$type" | sed "s/'/''/g")
      settings_esc=$(add_event_entry "$settings_esc" "Stop"         "$st" "$type" | sed "s/'/''/g")
      ;;
    off)
      : # already stripped
      ;;
    *)
      echo "Unknown mode: $mode (use monitor|turn|both|off)" >&2
      return 1
      ;;
  esac

  settings_esc=$(prune_empty_hooks "$settings_esc")

  # Unescape for write.
  printf '%s' "$settings_esc" | sed "s/''/'/g" > "$hooks_file"
}

emit_monitor_directive() {
  local type="$1"
  local project="$2"
  local watch="$SKILL_DIR/scripts/watch.sh"

  # Claude Code exports CLAUDE_CODE_SESSION_ID for every subprocess of the
  # session. Bake it directly into the command so the agent never has to
  # invent a value — that lets SessionEnd find and clean the matching
  # pidfile reliably. Fall back to a generated id when the env var isn't
  # present (older CC, non-CC runtimes).
  local session_id="${CLAUDE_CODE_SESSION_ID:-}"
  if [ -z "$session_id" ]; then
    if command -v uuidgen >/dev/null 2>&1; then
      session_id="agmsg-$(uuidgen | tr 'A-Z' 'a-z')"
    else
      session_id="agmsg-$(date +%s)-$$"
    fi
  fi

  # Skip the directive when this CC session already has a live watcher —
  # invoking Monitor again would just spawn a duplicate and orphan the
  # previous watcher process.
  local pidfile="$RUN_DIR/watch.$session_id.pid"
  if [ -f "$pidfile" ]; then
    local existing
    existing=$(cat "$pidfile" 2>/dev/null || true)
    if [ -n "$existing" ] && kill -0 "$existing" 2>/dev/null; then
      cat <<EOF

A watch.sh is already streaming into this session (pid $existing). No
action needed — the existing watcher is the active one.
EOF
      return 0
    fi
  fi

  cat <<EOF

AGMSG-DIRECTIVE: For this running session, invoke the Monitor tool now with:
  command: $watch $session_id $project $type
  description: agmsg inbox stream
  persistent: true

Pass the command above verbatim — the session_id is already filled in.
EOF
}

emit_stop_directive() {
  cat <<'EOF'

AGMSG-DIRECTIVE: If an agmsg watch Monitor task is running in this session,
find it with TaskList (description starts with "agmsg inbox stream") and
stop it with TaskStop. Existing watch.sh processes have already been killed
by this command.
EOF
}

do_set() {
  local MODE="${1:?Usage: delivery.sh set <mode> <type> <project_path>}"
  local TYPE="${2:?Missing type}"
  local PROJECT="${3:?Missing project_path}"

  case "$MODE" in monitor|turn|both|off) ;; *)
    echo "Unknown mode: $MODE (use monitor|turn|both|off)" >&2; exit 1 ;;
  esac

  if [ "$TYPE" = "cursor" ]; then
    case "$MODE" in monitor|both)
      echo "Cursor CLI does not support delivery mode '$MODE' (supported: turn, off)" >&2
      exit 1
      ;;
    esac
  fi

  apply_settings "$TYPE" "$PROJECT" "$MODE"

  echo "Delivery mode set to '$MODE' for $PROJECT ($TYPE)"

  if [ "$TYPE" = "cursor" ]; then
    case "$MODE" in
      turn)
        echo "Future sessions: stop hook checks inbox between turns (interactive cursor-agent)."
        echo "Note: headless cursor-agent --print may not fire stop hooks."
        ;;
      off)
        echo "Future sessions: no automatic delivery."
        ;;
    esac
    return 0
  fi

  case "$MODE" in
    monitor|both)
      echo "Future sessions: SessionStart hook will auto-launch the watcher."
      emit_monitor_directive "$TYPE" "$PROJECT"
      ;;
    turn)
      echo "Future sessions: Stop hook will check inbox between turns."
      # Stop only THIS project's watcher; other projects/sessions keep theirs.
      kill_all_watchers "$PROJECT" >/dev/null 2>&1 || true
      emit_stop_directive
      ;;
    off)
      echo "Future sessions: no automatic delivery."
      kill_all_watchers "$PROJECT" >/dev/null 2>&1 || true
      emit_stop_directive
      ;;
  esac
}

do_status() {
  local TYPE="${1:-}"
  local PROJECT="${2:-}"

  # Mode is derived from the project's settings.local.json — there's no
  # global mode value. When called without <type> <project>, we can't infer
  # a project-scoped mode, so we just skip the mode line and report the
  # global watcher state below.
  if [ -n "$TYPE" ] && [ -n "$PROJECT" ]; then
    local hf
    hf=$(resolve_hooks_file "$TYPE" "$PROJECT")
    if [ "$TYPE" = "cursor" ]; then
      local mode="off"
      if [ -f "$hf" ]; then
        local expected_tmp expected_tmp_esc hf_esc has_agmsg
        expected_tmp=$(mktemp)
        printf '%s' "$(cursor_expected_command "$PROJECT")" > "$expected_tmp"
        expected_tmp_esc=$(sql_path_escape "$expected_tmp")
        hf_esc=$(sql_path_escape "$hf")
        has_agmsg=$(sqlite3 :memory: "
          SELECT EXISTS(
            SELECT 1 FROM json_each(json_extract(readfile('$hf_esc'), '\$.hooks.stop')) AS h
            WHERE json_extract(h.value, '\$.command') = cast(readfile('$expected_tmp_esc') as text)
          );" 2>/dev/null || echo 0)
        rm -f "$expected_tmp"
        [ "$has_agmsg" = "1" ] && mode="turn"
      fi
      echo "mode: $mode"
    elif [ "$TYPE" = "gemini" ] || [ "$TYPE" = "antigravity" ] || [ "$TYPE" = "copilot" ]; then
      local mode="off"
      if [ -f "$hf" ]; then
        mode="turn"
      fi
      echo "mode: $mode"
    else
      local has_ss=0 has_st=0
      if [ -f "$hf" ]; then
        has_ss=$(sqlite3 :memory: "
          SELECT EXISTS(
            SELECT 1 FROM json_each(json_extract(readfile('$hf'), '\$.hooks.SessionStart')) AS s,
              json_each(json_extract(s.value, '\$.hooks')) AS h
            WHERE instr(json_extract(h.value, '\$.command'), '$SKILL_NAME') > 0
          );" 2>/dev/null || echo 0)
        has_st=$(sqlite3 :memory: "
          SELECT EXISTS(
            SELECT 1 FROM json_each(json_extract(readfile('$hf'), '\$.hooks.Stop')) AS s,
              json_each(json_extract(s.value, '\$.hooks')) AS h
            WHERE instr(json_extract(h.value, '\$.command'), '$SKILL_NAME') > 0
          );" 2>/dev/null || echo 0)
      fi
      local mode="off"
      if [ "$has_ss" = "1" ] && [ "$has_st" = "1" ]; then mode="both"
      elif [ "$has_ss" = "1" ]; then mode="monitor"
      elif [ "$has_st" = "1" ]; then mode="turn"
      fi
      echo "mode: $mode"
    fi
  fi

  if [ -n "$TYPE" ] && [ -n "$PROJECT" ] && [ "$TYPE" != "gemini" ] && [ "$TYPE" != "antigravity" ] && [ "$TYPE" != "cursor" ] && [ "$TYPE" != "copilot" ]; then
    local hooks_file
    hooks_file=$(resolve_hooks_file "$TYPE" "$PROJECT")
    if [ -f "$hooks_file" ]; then
      local count
      count=$(sqlite3 :memory: "SELECT json_array_length(json_extract('$(read_settings_escaped "$hooks_file")', '\$.hooks.SessionStart'));" 2>/dev/null || echo 0)
      case "$count" in ''|*[!0-9]*) count=0 ;; esac
      echo "settings hooks file: $hooks_file"
      echo "  SessionStart entries: $count"
      count=$(sqlite3 :memory: "SELECT json_array_length(json_extract('$(read_settings_escaped "$hooks_file")', '\$.hooks.SessionEnd'));" 2>/dev/null || echo 0)
      case "$count" in ''|*[!0-9]*) count=0 ;; esac
      echo "  SessionEnd entries:   $count"
      count=$(sqlite3 :memory: "SELECT json_array_length(json_extract('$(read_settings_escaped "$hooks_file")', '\$.hooks.Stop'));" 2>/dev/null || echo 0)
      case "$count" in ''|*[!0-9]*) count=0 ;; esac
      echo "  Stop entries:         $count"
    fi
  fi

  if [ -d "$RUN_DIR" ]; then
    local alive=0 dead=0
    for f in "$RUN_DIR"/watch.*.pid; do
      [ -f "$f" ] || continue
      local pid
      pid=$(cat "$f" 2>/dev/null || echo "")
      if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        alive=$((alive + 1))
      else
        dead=$((dead + 1))
      fi
    done
    echo "watch processes: $alive alive, $dead stale pidfiles"
  fi
}

kill_all_watchers() {
  # With no argument, kills every running watch.sh (used by stop/restart).
  # With a <project> argument, kills only watchers launched for that project
  # path, so switching one project's delivery mode (set turn/off) never tears
  # down another project's — or another concurrent session's — monitor.
  local project="${1:-}"
  local killed=0
  if [ -d "$RUN_DIR" ]; then
    for f in "$RUN_DIR"/watch.*.pid; do
      [ -f "$f" ] || continue
      local pid cmd
      pid=$(cat "$f" 2>/dev/null || echo "")
      if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        # Defensive: only kill if the pid's command line still looks like
        # our watch.sh. Defends against pid recycling — a stale pidfile
        # could point at an unrelated process that reused the pid.
        cmd=$(ps -o args= -p "$pid" 2>/dev/null || true)
        case "$cmd" in
          *"$SKILL_DIR/scripts/watch.sh"*)
            # watch.sh argv is "watch.sh <session_id> <project> <type> [name]",
            # so the project path is a space-delimited field. When scoped,
            # skip (and preserve the pidfile of) watchers for other projects.
            if [ -n "$project" ]; then
              case " $cmd " in
                *" $project "*) ;;
                *) continue ;;
              esac
            fi
            kill "$pid" 2>/dev/null && killed=$((killed + 1)) ;;
          *) ;;  # not our watcher; leave it
        esac
      fi
      rm -f "$f"
    done
  fi
  echo "$killed"
}

do_stop() {
  local killed
  killed=$(kill_all_watchers)
  echo "Killed $killed watch process(es)."
  emit_stop_directive
}

do_restart() {
  local TYPE="${1:-}"
  local PROJECT="${2:-}"
  local killed
  killed=$(kill_all_watchers)
  echo "Killed $killed watch process(es)."
  if [ -n "$TYPE" ] && [ -n "$PROJECT" ]; then
    emit_stop_directive
    emit_monitor_directive "$TYPE" "$PROJECT"
  else
    emit_stop_directive
    cat <<'EOF'

To relaunch in this session, pass <type> <project_path> as arguments:
  delivery.sh restart claude-code /path/to/project
EOF
  fi
}

case "$ACTION" in
  set)     do_set "$@" ;;
  status)  do_status "$@" ;;
  stop)    do_stop "$@" ;;
  restart) do_restart "$@" ;;
  *)       echo "Unknown action: $ACTION (use set|status|stop|restart)" >&2; exit 1 ;;
esac
