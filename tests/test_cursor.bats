#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  export TEST_PROJECT="$(mktemp -d)"
}

teardown() {
  rm -rf "$TEST_PROJECT"
  teardown_test_env
}

cursor_hooks_file() {
  echo "$TEST_PROJECT/.cursor/hooks.json"
}

cursor_rule_file() {
  echo "$TEST_PROJECT/.cursor/rules/agmsg.mdc"
}

posix_shell_quote() {
  local s="$1"
  printf "'%s'" "$(printf '%s' "$s" | sed "s/'/'\\\\''/g")"
}

cursor_normalize_project() {
  local project="$1"
  if [ -d "$project" ]; then
    (cd "$project" && pwd -P)
  elif command -v realpath >/dev/null 2>&1; then
    realpath -m "$project" 2>/dev/null || printf '%s' "$project"
  else
    printf '%s' "$project"
  fi
}

expected_cursor_command() {
  local project="$1"
  project=$(cursor_normalize_project "$project")
  printf '%s %s' \
    "$(posix_shell_quote "$TEST_SKILL_DIR/scripts/check-inbox-cursor.sh")" \
    "$(posix_shell_quote "$project")"
}

agmsg_cursor_stop_count() {
  local file="$1"
  local project="$2"
  if [ ! -f "$file" ]; then echo 0; return; fi
  local expected_esc
  expected_esc=$(printf '%s' "$(expected_cursor_command "$project")" | sed "s/'/''/g")
  local file_esc
  file_esc=$(printf '%s' "$file" | sed "s/'/''/g")
  sqlite3 :memory: "
    SELECT count(*) FROM json_each(json_extract(readfile('$file_esc'), '\$.hooks.stop')) AS h
    WHERE json_extract(h.value, '\$.command') = '$expected_esc';
  " 2>/dev/null || echo 0
}

hooks_json_valid() {
  local file="$1"
  local file_esc
  file_esc=$(printf '%s' "$file" | sed "s/'/''/g")
  [ "$(sqlite3 :memory: "SELECT json_valid(readfile('$file_esc'));" 2>/dev/null || echo 0)" = "1" ]
}

# --- join ---

@test "join: accepts cursor" {
  run bash "$SCRIPTS/join.sh" myteam alice cursor /tmp/proj
  [ "$status" -eq 0 ]
}

@test "join: unknown type error lists cursor" {
  run bash "$SCRIPTS/join.sh" myteam alice bogus /tmp/proj
  [ "$status" -ne 0 ]
  [[ "$output" =~ "cursor" ]]
}

@test "cmd.cursor.md: self-install command includes --agent-type cursor" {
  grep -Fq './install.sh --cmd __SKILL_NAME__ --agent-type cursor' \
    "$BATS_TEST_DIRNAME/../templates/cmd.cursor.md"
}

@test "install: cmd.cursor.md template documents cursor agent-type install" {
  local home
  home="$(mktemp -d)"
  run env HOME="$home" bash "$BATS_TEST_DIRNAME/../install.sh" --cmd mycmd --agent-type cursor
  [ "$status" -eq 0 ]
  grep -Fq './install.sh --cmd mycmd --agent-type cursor' \
    "$home/.agents/skills/mycmd/templates/cmd.cursor.md"
  rm -rf "$home"
}

@test "install: copies cursor rule template into installed skill templates" {
  local home installed_rule
  home="$(mktemp -d)"
  run env HOME="$home" bash "$BATS_TEST_DIRNAME/../install.sh" --cmd agmsgtest
  [ "$status" -eq 0 ]
  installed_rule="$home/.agents/skills/agmsgtest/templates/cursor-rule.mdc"
  [ -f "$installed_rule" ]
  grep -Fq 'alwaysApply: true' "$installed_rule"
  grep -Fq '~/.agents/skills/agmsgtest/scripts/whoami.sh "$(pwd)" cursor' "$installed_rule"
  rm -rf "$home"
}

# --- delivery set turn ---

@test "delivery set turn cursor: creates .cursor/hooks.json" {
  run bash "$SCRIPTS/delivery.sh" set turn cursor "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [ -f "$(cursor_hooks_file)" ]
}

@test "delivery set turn cursor: creates managed .cursor/rules/agmsg.mdc" {
  run bash "$SCRIPTS/delivery.sh" set turn cursor "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [ -f "$(cursor_rule_file)" ]
  grep -Fq '<!-- agmsg:managed file=agmsg.mdc -->' "$(cursor_rule_file)"
  grep -Fq 'alwaysApply: true' "$(cursor_rule_file)"
}

@test "delivery set turn cursor: rule contains Cursor operational guidance" {
  bash "$SCRIPTS/delivery.sh" set turn cursor "$TEST_PROJECT"
  grep -Fq 'whoami.sh "$(pwd)" cursor' "$(cursor_rule_file)"
  grep -Fq 'supports only `turn` and `off`' "$(cursor_rule_file)"
  grep -Fq 'followup_message' "$(cursor_rule_file)"
  grep -Fq 'does not use Codex-style `decision:block` or' "$(cursor_rule_file)"
  grep -Fq 'systemMessage' "$(cursor_rule_file)"
}

@test "delivery set turn cursor: missing rule template fails before creating hooks.json" {
  mv "$TEST_SKILL_DIR/templates/cursor-rule.mdc" "$TEST_SKILL_DIR/templates/cursor-rule.mdc.bak"
  run bash "$SCRIPTS/delivery.sh" set turn cursor "$TEST_PROJECT"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "Cursor rule template not found" ]]
  [ ! -f "$(cursor_hooks_file)" ]
  [ ! -f "$(cursor_rule_file)" ]
}

@test "delivery set turn cursor: missing rule template leaves existing hooks unchanged" {
  mkdir -p "$TEST_PROJECT/.cursor"
  cat > "$(cursor_hooks_file)" <<'JSON'
{
  "version": 1,
  "hooks": {
    "stop": [{"command": "other-hook.sh", "loop_limit": 2}]
  }
}
JSON
  local before
  before=$(cat "$(cursor_hooks_file)")
  mv "$TEST_SKILL_DIR/templates/cursor-rule.mdc" "$TEST_SKILL_DIR/templates/cursor-rule.mdc.bak"
  run bash "$SCRIPTS/delivery.sh" set turn cursor "$TEST_PROJECT"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "Cursor rule template not found" ]]
  [ "$(cat "$(cursor_hooks_file)")" = "$before" ]
  local n
  n=$(agmsg_cursor_stop_count "$(cursor_hooks_file)" "$TEST_PROJECT")
  [ "$n" = "0" ]
  grep -q 'other-hook.sh' "$(cursor_hooks_file)"
}

@test "delivery set turn cursor: schema version 1 and hooks.stop" {
  bash "$SCRIPTS/delivery.sh" set turn cursor "$TEST_PROJECT"
  local v
  v=$(sqlite3 :memory: "SELECT json_extract(readfile('$(cursor_hooks_file)'), '\$.version');")
  [ "$v" = "1" ]
  local n
  n=$(sqlite3 :memory: "SELECT json_array_length(json_extract(readfile('$(cursor_hooks_file)'), '\$.hooks.stop'));")
  [ "$n" = "1" ]
  ! grep -q '"Stop"' "$(cursor_hooks_file)"
}

@test "delivery set turn cursor: command points to check-inbox-cursor.sh with loop_limit" {
  bash "$SCRIPTS/delivery.sh" set turn cursor "$TEST_PROJECT"
  local cmd limit
  cmd=$(sqlite3 :memory: "SELECT json_extract(readfile('$(cursor_hooks_file)'), '\$.hooks.stop[0].command');")
  limit=$(sqlite3 :memory: "SELECT json_extract(readfile('$(cursor_hooks_file)'), '\$.hooks.stop[0].loop_limit');")
  [[ "$cmd" =~ "check-inbox-cursor.sh" ]]
  [[ "$cmd" =~ "$TEST_PROJECT" ]]
  [ "$limit" = "1" ]
}

# --- idempotency / merge ---

@test "delivery set turn cursor: idempotent" {
  bash "$SCRIPTS/delivery.sh" set turn cursor "$TEST_PROJECT"
  bash "$SCRIPTS/delivery.sh" set turn cursor "$TEST_PROJECT"
  bash "$SCRIPTS/delivery.sh" set turn cursor "$TEST_PROJECT"
  local n
  n=$(agmsg_cursor_stop_count "$(cursor_hooks_file)" "$TEST_PROJECT")
  [ "$n" = "1" ]
  local marker_count
  marker_count=$(grep -F -c '<!-- agmsg:managed file=agmsg.mdc -->' "$(cursor_rule_file)")
  [ "$marker_count" = "1" ]
}

@test "delivery set turn cursor: updates existing managed agmsg rule" {
  mkdir -p "$TEST_PROJECT/.cursor/rules"
  cat > "$(cursor_rule_file)" <<'EOF'
<!-- agmsg:managed file=agmsg.mdc -->
old content
EOF
  bash "$SCRIPTS/delivery.sh" set turn cursor "$TEST_PROJECT"
  grep -Fq 'alwaysApply: true' "$(cursor_rule_file)"
  ! grep -Fq 'old content' "$(cursor_rule_file)"
}

@test "delivery set turn cursor: preserves existing unmarked agmsg rule and still configures hook" {
  mkdir -p "$TEST_PROJECT/.cursor/rules"
  printf 'custom cursor rule\n' > "$(cursor_rule_file)"
  run bash "$SCRIPTS/delivery.sh" set turn cursor "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "exists without agmsg marker" ]]
  [ "$(cat "$(cursor_rule_file)")" = "custom cursor rule" ]
  local n
  n=$(agmsg_cursor_stop_count "$(cursor_hooks_file)" "$TEST_PROJECT")
  [ "$n" = "1" ]
}

@test "delivery set turn cursor: preserves other cursor rule files" {
  mkdir -p "$TEST_PROJECT/.cursor/rules"
  printf 'other rule\n' > "$TEST_PROJECT/.cursor/rules/other.mdc"
  bash "$SCRIPTS/delivery.sh" set turn cursor "$TEST_PROJECT"
  [ "$(cat "$TEST_PROJECT/.cursor/rules/other.mdc")" = "other rule" ]
  [ -f "$(cursor_rule_file)" ]
}

@test "delivery set turn cursor: preserves other hook events" {
  mkdir -p "$TEST_PROJECT/.cursor"
  cat > "$(cursor_hooks_file)" <<'JSON'
{
  "version": 1,
  "hooks": {
    "sessionStart": [{"command": "echo hi"}]
  }
}
JSON
  bash "$SCRIPTS/delivery.sh" set turn cursor "$TEST_PROJECT"
  local n
  n=$(sqlite3 :memory: "SELECT json_array_length(json_extract(readfile('$(cursor_hooks_file)'), '\$.hooks.sessionStart'));")
  [ "$n" = "1" ]
}

@test "delivery set turn cursor: preserves other stop hooks" {
  mkdir -p "$TEST_PROJECT/.cursor"
  cat > "$(cursor_hooks_file)" <<'JSON'
{
  "version": 1,
  "hooks": {
    "stop": [{"command": "other-hook.sh", "loop_limit": 2}]
  }
}
JSON
  bash "$SCRIPTS/delivery.sh" set turn cursor "$TEST_PROJECT"
  local n
  n=$(sqlite3 :memory: "SELECT json_array_length(json_extract(readfile('$(cursor_hooks_file)'), '\$.hooks.stop'));")
  [ "$n" = "2" ]
  grep -q 'other-hook.sh' "$(cursor_hooks_file)"
}

@test "delivery set turn cursor: preserves arbitrary top-level keys" {
  mkdir -p "$TEST_PROJECT/.cursor"
  echo '{"version":1,"custom":true,"hooks":{}}' > "$(cursor_hooks_file)"
  bash "$SCRIPTS/delivery.sh" set turn cursor "$TEST_PROJECT"
  local c
  c=$(sqlite3 :memory: "SELECT json_extract(readfile('$(cursor_hooks_file)'), '\$.custom');")
  [ "$c" = "1" ]
}

@test "delivery set turn cursor: path with spaces in command" {
  local spaced="$(mktemp -d)/my project"
  mkdir -p "$spaced"
  bash "$SCRIPTS/delivery.sh" set turn cursor "$spaced"
  local cmd
  cmd=$(sqlite3 :memory: "SELECT json_extract(readfile('$spaced/.cursor/hooks.json'), '\$.hooks.stop[0].command');")
  [[ "$cmd" =~ "my project" ]]
  [[ "$cmd" =~ "check-inbox-cursor.sh" ]]
  [ -f "$spaced/.cursor/rules/agmsg.mdc" ]
  rm -rf "$(dirname "$spaced")"
}

@test "delivery set turn cursor: path with double quote produces valid JSON" {
  local base parent weird
  base="$(mktemp -d)"
  parent="$base/a\"b"
  mkdir -p "$parent"
  bash "$SCRIPTS/delivery.sh" set turn cursor "$parent"
  weird="$parent/.cursor/hooks.json"
  hooks_json_valid "$weird"
  local cmd
  cmd=$(sqlite3 :memory: "SELECT json_extract(readfile('$weird'), '\$.hooks.stop[0].command');")
  [[ "$cmd" =~ "check-inbox-cursor.sh" ]]
  [ "$cmd" = "$(expected_cursor_command "$parent")" ]
  rm -rf "$base"
}

@test "delivery set turn cursor: path with single quote produces valid JSON" {
  local base parent hooks hooks_esc cmd
  base="$(mktemp -d)"
  parent="$base/a'b"
  mkdir -p "$parent"
  bash "$SCRIPTS/delivery.sh" set turn cursor "$parent"
  hooks="$parent/.cursor/hooks.json"
  hooks_json_valid "$hooks"
  hooks_esc=$(printf '%s' "$hooks" | sed "s/'/''/g")
  cmd=$(sqlite3 :memory: "SELECT json_extract(readfile('$hooks_esc'), '\$.hooks.stop[0].command');")
  [[ "$cmd" =~ "check-inbox-cursor.sh" ]]
  [ "$cmd" = "$(expected_cursor_command "$parent")" ]
  rm -rf "$base"
}

@test "delivery set turn cursor: path with backslash produces valid JSON" {
  local base parent
  base="$(mktemp -d)"
  parent="$base/a\\b"
  mkdir -p "$parent"
  bash "$SCRIPTS/delivery.sh" set turn cursor "$parent"
  hooks_json_valid "$parent/.cursor/hooks.json"
  local cmd
  cmd=$(sqlite3 :memory: "SELECT json_extract(readfile('$parent/.cursor/hooks.json'), '\$.hooks.stop[0].command');")
  [[ "$cmd" =~ "check-inbox-cursor.sh" ]]
  [ "$cmd" = "$(expected_cursor_command "$parent")" ]
  rm -rf "$base"
}

@test "delivery set off cursor: does not remove foreign hook mentioning check-inbox-cursor.sh" {
  mkdir -p "$TEST_PROJECT/.cursor"
  cat > "$(cursor_hooks_file)" <<'JSON'
{
  "version": 1,
  "hooks": {
    "stop": [{"command": "echo check-inbox-cursor.sh /tmp/not-agmsg", "loop_limit": 2}]
  }
}
JSON
  bash "$SCRIPTS/delivery.sh" set turn cursor "$TEST_PROJECT"
  bash "$SCRIPTS/delivery.sh" set off cursor "$TEST_PROJECT"
  local n
  n=$(sqlite3 :memory: "SELECT json_array_length(json_extract(readfile('$(cursor_hooks_file)'), '\$.hooks.stop'));")
  [ "$n" = "1" ]
  grep -q 'echo check-inbox-cursor.sh' "$(cursor_hooks_file)"
  ! grep -q "$TEST_SKILL_DIR" "$(cursor_hooks_file)" || true
}

@test "delivery status cursor: foreign hook is not turn mode" {
  mkdir -p "$TEST_PROJECT/.cursor"
  cat > "$(cursor_hooks_file)" <<'JSON'
{
  "version": 1,
  "hooks": {
    "stop": [{"command": "wrapper check-inbox-cursor.sh /other/project", "loop_limit": 1}]
  }
}
JSON
  run bash "$SCRIPTS/delivery.sh" status cursor "$TEST_PROJECT"
  [[ "$output" =~ "mode: off" ]]
}

@test "delivery set turn cursor: hooks.stop must be array" {
  mkdir -p "$TEST_PROJECT/.cursor"
  echo '{"version":1,"hooks":{"stop":"not-array"}}' > "$(cursor_hooks_file)"
  run bash "$SCRIPTS/delivery.sh" set turn cursor "$TEST_PROJECT"
  [ "$status" -ne 0 ]
  grep -q 'not-array' "$(cursor_hooks_file)"
}

@test "delivery set turn cursor: hooks must be object when array" {
  mkdir -p "$TEST_PROJECT/.cursor"
  echo '{"version":1,"hooks":[]}' > "$(cursor_hooks_file)"
  run bash "$SCRIPTS/delivery.sh" set turn cursor "$TEST_PROJECT"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "hooks must be a JSON object" ]]
  [ "$(cat "$(cursor_hooks_file)")" = '{"version":1,"hooks":[]}' ]
}

@test "delivery set turn cursor: hooks must be object when string" {
  mkdir -p "$TEST_PROJECT/.cursor"
  echo '{"version":1,"hooks":"bad"}' > "$(cursor_hooks_file)"
  run bash "$SCRIPTS/delivery.sh" set turn cursor "$TEST_PROJECT"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "hooks must be a JSON object" ]]
  grep -q '"hooks":"bad"' "$(cursor_hooks_file)"
}

# --- off / status ---

@test "delivery status cursor: turn and off" {
  run bash "$SCRIPTS/delivery.sh" status cursor "$TEST_PROJECT"
  [[ "$output" =~ "mode: off" ]]
  bash "$SCRIPTS/delivery.sh" set turn cursor "$TEST_PROJECT" >/dev/null
  run bash "$SCRIPTS/delivery.sh" status cursor "$TEST_PROJECT"
  [[ "$output" =~ "mode: turn" ]]
  bash "$SCRIPTS/delivery.sh" set off cursor "$TEST_PROJECT" >/dev/null
  run bash "$SCRIPTS/delivery.sh" status cursor "$TEST_PROJECT"
  [[ "$output" =~ "mode: off" ]]
}

@test "delivery set off cursor: preserves stop entry with missing command" {
  mkdir -p "$TEST_PROJECT/.cursor"
  cat > "$(cursor_hooks_file)" <<'JSON'
{
  "version": 1,
  "hooks": {
    "stop": [{"loop_limit": 2}]
  }
}
JSON
  bash "$SCRIPTS/delivery.sh" set turn cursor "$TEST_PROJECT"
  bash "$SCRIPTS/delivery.sh" set off cursor "$TEST_PROJECT"
  local n limit cmd_type
  n=$(sqlite3 :memory: "SELECT json_array_length(json_extract(readfile('$(cursor_hooks_file)'), '\$.hooks.stop'));")
  [ "$n" = "1" ]
  limit=$(sqlite3 :memory: "SELECT json_extract(readfile('$(cursor_hooks_file)'), '\$.hooks.stop[0].loop_limit');")
  [ "$limit" = "2" ]
  local cmd_val
  cmd_val=$(sqlite3 :memory: "SELECT json_extract(readfile('$(cursor_hooks_file)'), '\$.hooks.stop[0].command');")
  [ -z "$cmd_val" ]
}

@test "delivery set off cursor: preserves stop entry with null command" {
  mkdir -p "$TEST_PROJECT/.cursor"
  cat > "$(cursor_hooks_file)" <<'JSON'
{
  "version": 1,
  "hooks": {
    "stop": [{"command": null, "loop_limit": 2}]
  }
}
JSON
  bash "$SCRIPTS/delivery.sh" set turn cursor "$TEST_PROJECT"
  bash "$SCRIPTS/delivery.sh" set off cursor "$TEST_PROJECT"
  local n limit
  n=$(sqlite3 :memory: "SELECT json_array_length(json_extract(readfile('$(cursor_hooks_file)'), '\$.hooks.stop'));")
  [ "$n" = "1" ]
  limit=$(sqlite3 :memory: "SELECT json_extract(readfile('$(cursor_hooks_file)'), '\$.hooks.stop[0].loop_limit');")
  [ "$limit" = "2" ]
}

@test "delivery set off cursor: removes only agmsg stop hook" {
  mkdir -p "$TEST_PROJECT/.cursor"
  cat > "$(cursor_hooks_file)" <<'JSON'
{
  "version": 1,
  "hooks": {
    "stop": [{"command": "other-hook.sh", "loop_limit": 2}]
  }
}
JSON
  bash "$SCRIPTS/delivery.sh" set turn cursor "$TEST_PROJECT"
  bash "$SCRIPTS/delivery.sh" set off cursor "$TEST_PROJECT"
  local n
  n=$(sqlite3 :memory: "SELECT json_array_length(json_extract(readfile('$(cursor_hooks_file)'), '\$.hooks.stop'));")
  [ "$n" = "1" ]
  grep -q 'other-hook.sh' "$(cursor_hooks_file)"
  ! grep -q 'check-inbox-cursor.sh' "$(cursor_hooks_file)"
}

@test "delivery set off cursor: removes hook but keeps managed rule" {
  bash "$SCRIPTS/delivery.sh" set turn cursor "$TEST_PROJECT"
  bash "$SCRIPTS/delivery.sh" set off cursor "$TEST_PROJECT"
  [ -f "$(cursor_rule_file)" ]
  local n
  n=$(agmsg_cursor_stop_count "$(cursor_hooks_file)" "$TEST_PROJECT")
  [ "$n" = "0" ]
}

@test "delivery set monitor cursor: rejected" {
  run bash "$SCRIPTS/delivery.sh" set monitor cursor "$TEST_PROJECT"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "does not support" ]]
  [ ! -f "$(cursor_hooks_file)" ] || ! grep -q 'check-inbox-cursor' "$(cursor_hooks_file)" 2>/dev/null
  [ ! -f "$(cursor_rule_file)" ]
}

@test "delivery set both cursor: rejected" {
  run bash "$SCRIPTS/delivery.sh" set both cursor "$TEST_PROJECT"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "does not support" ]]
  [ ! -f "$(cursor_rule_file)" ]
}

@test "delivery set turn cursor: invalid JSON is not overwritten" {
  mkdir -p "$TEST_PROJECT/.cursor"
  echo '{not json' > "$(cursor_hooks_file)"
  run bash "$SCRIPTS/delivery.sh" set turn cursor "$TEST_PROJECT"
  [ "$status" -ne 0 ]
  grep -q 'not json' "$(cursor_hooks_file)"
}

# --- check-inbox-cursor.sh ---

@test "check-inbox-cursor: not joined returns {}" {
  run bash -c "echo '{}' | bash '$SCRIPTS/check-inbox-cursor.sh' '$TEST_PROJECT'"
  [ "$status" -eq 0 ]
  [ "$output" = "{}" ]
}

@test "check-inbox-cursor: no unread returns {}" {
  bash "$SCRIPTS/join.sh" testteam alice cursor "$TEST_PROJECT"
  run bash -c "echo '{}' | bash '$SCRIPTS/check-inbox-cursor.sh' '$TEST_PROJECT'"
  [ "$status" -eq 0 ]
  [ "$output" = "{}" ]
}

@test "check-inbox-cursor: cooldown returns {}" {
  bash "$SCRIPTS/join.sh" testteam alice cursor "$TEST_PROJECT"
  bash "$SCRIPTS/send.sh" testteam bob alice "hello"
  echo '{}' | bash "$SCRIPTS/check-inbox-cursor.sh" "$TEST_PROJECT" >/dev/null
  bash "$SCRIPTS/send.sh" testteam bob alice "again"
  run bash -c "echo '{}' | bash '$SCRIPTS/check-inbox-cursor.sh' '$TEST_PROJECT'"
  [ "$status" -eq 0 ]
  [ "$output" = "{}" ]
}

@test "check-inbox-cursor: loop_count at limit returns {}" {
  bash "$SCRIPTS/join.sh" testteam alice cursor "$TEST_PROJECT"
  bash "$SCRIPTS/send.sh" testteam bob alice "hello"
  run bash -c 'echo "{\"loop_count\":1}" | bash "'"$SCRIPTS"'/check-inbox-cursor.sh" "'"$TEST_PROJECT"'"'
  [ "$status" -eq 0 ]
  [ "$output" = "{}" ]
}

@test "check-inbox-cursor: unread returns followup_message JSON" {
  bash "$SCRIPTS/join.sh" testteam alice cursor "$TEST_PROJECT"
  bash "$SCRIPTS/send.sh" testteam bob alice "please review"
  run bash -c "echo '{}' | bash '$SCRIPTS/check-inbox-cursor.sh' '$TEST_PROJECT'"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "followup_message" ]]
  [[ "$output" =~ "please review" ]]
  echo "$output" | python3 -c "import json,sys; json.load(sys.stdin)"
}

@test "check-inbox-cursor: escapes special characters in body" {
  bash "$SCRIPTS/join.sh" testteam alice cursor "$TEST_PROJECT"
  bash "$SCRIPTS/send.sh" testteam bob alice $'say "hi"\\path\nand\ttab'
  run bash -c "echo '{}' | bash '$SCRIPTS/check-inbox-cursor.sh' '$TEST_PROJECT'"
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); assert 'followup_message' in d"
}

@test "check-inbox-cursor: marks messages read after notify" {
  bash "$SCRIPTS/join.sh" testteam alice cursor "$TEST_PROJECT"
  bash "$SCRIPTS/send.sh" testteam bob alice "read-me"
  echo '{}' | bash "$SCRIPTS/check-inbox-cursor.sh" "$TEST_PROJECT" >/dev/null
  local unread
  unread=$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" \
    "SELECT count(*) FROM messages WHERE team='testteam' AND to_agent='alice' AND read_at IS NULL;")
  [ "$unread" = "0" ]
}

@test "check-inbox-cursor: multiple identities returns {}" {
  bash "$SCRIPTS/join.sh" teama alice cursor "$TEST_PROJECT"
  bash "$SCRIPTS/join.sh" teamb bob cursor "$TEST_PROJECT"
  bash "$SCRIPTS/send.sh" teama carol alice "for alice"
  run bash -c "echo '{}' | bash '$SCRIPTS/check-inbox-cursor.sh' '$TEST_PROJECT'"
  [ "$status" -eq 0 ]
  [ "$output" = "{}" ]
}

@test "check-inbox-cursor: team name with single quote returns valid JSON" {
  python3 -c "
import json, pathlib
team = \"team'x\"
root = pathlib.Path('$TEST_SKILL_DIR') / 'teams' / team
root.mkdir(parents=True, exist_ok=True)
json.dump({
  'name': team,
  'agents': {'alice': {'type': 'cursor', 'project': '$TEST_PROJECT'}},
  'created_at': '2026-01-01T00:00:00Z',
}, open(root / 'config.json', 'w'))
"
  python3 -c "
import sqlite3
db = sqlite3.connect('$TEST_SKILL_DIR/db/messages.db')
db.execute(\"INSERT INTO messages (team, from_agent, to_agent, body) VALUES (?, ?, ?, ?)\",
            (\"team'x\", 'bob', 'alice', 'hello'))
db.commit()
"
  run bash -c "echo '{}' | bash '$SCRIPTS/check-inbox-cursor.sh' '$TEST_PROJECT'"
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "import json,sys; json.load(sys.stdin)"
}

@test "check-inbox-cursor: agent name with single quote returns valid JSON" {
  python3 -c "
import json, pathlib
root = pathlib.Path('$TEST_SKILL_DIR') / 'teams' / 'testteam'
root.mkdir(parents=True, exist_ok=True)
json.dump({
  'name': 'testteam',
  'agents': {\"o'brien\": {'type': 'cursor', 'project': '$TEST_PROJECT'}},
  'created_at': '2026-01-01T00:00:00Z',
}, open(root / 'config.json', 'w'))
"
  python3 -c "
import sqlite3
db = sqlite3.connect('$TEST_SKILL_DIR/db/messages.db')
db.execute('INSERT INTO messages (team, from_agent, to_agent, body) VALUES (?, ?, ?, ?)',
            ('testteam', 'bob', \"o'brien\", 'hello'))
db.commit()
"
  run bash -c "echo '{}' | bash '$SCRIPTS/check-inbox-cursor.sh' '$TEST_PROJECT'"
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "import json,sys; json.load(sys.stdin)"
}

@test "identities: project path with single quote resolves without SQL error" {
  local base parent
  base="$(mktemp -d)"
  parent="$base/a'b"
  mkdir -p "$parent"
  bash "$SCRIPTS/join.sh" testteam alice cursor "$parent"
  run bash "$SCRIPTS/identities.sh" "$parent" cursor
  [ "$status" -eq 0 ]
  [[ "$output" =~ $'testteam\talice' ]]
  rm -rf "$base"
}

@test "check-inbox-cursor: project path with single quote returns valid JSON end-to-end" {
  local base parent
  base="$(mktemp -d)"
  parent="$base/a'b"
  mkdir -p "$parent"
  bash "$SCRIPTS/join.sh" testteam alice cursor "$parent"
  bash "$SCRIPTS/send.sh" testteam bob alice "hello from quote path"
  export QUOTE_PROJECT="$parent"
  run bash -c 'echo "{}" | bash "$SCRIPTS/check-inbox-cursor.sh" "$QUOTE_PROJECT"'
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); assert 'followup_message' in d"
  [[ "$output" =~ "hello from quote path" ]]
  rm -rf "$base"
}

@test "check-inbox-cursor: body with quote backslash newline tab CR is valid JSON" {
  bash "$SCRIPTS/join.sh" testteam alice cursor "$TEST_PROJECT"
  bash "$SCRIPTS/send.sh" testteam bob alice $'line1\rline2\n"q"\\end\t'
  run bash -c "echo '{}' | bash '$SCRIPTS/check-inbox-cursor.sh' '$TEST_PROJECT'"
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); assert 'followup_message' in d"
  local unread
  unread=$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" \
    "SELECT count(*) FROM messages WHERE team='testteam' AND to_agent='alice' AND read_at IS NULL;")
  [ "$unread" = "0" ]
}
