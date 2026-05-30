#!/usr/bin/env bash
set -euo pipefail

# List (team, agent) pairs registered for a given (project_path, agent_type).
#
# Usage: identities.sh <project_path> <agent_type>
#
# Output: one "<team>\t<agent>" line per registered pair, tab-separated.
# Empty output (and exit 0) when no pair matches. Pairs are deduplicated.
#
# Used by:
#   - whoami.sh        — exact-match enumeration for identity resolution
#   - watch.sh         — subscription set for the monitor delivery mode
#   - check-inbox.sh   — turn-mode fallback enumeration

PROJECT_PATH="${1:?Usage: identities.sh <project_path> <agent_type>}"
AGENT_TYPE="${2:?Missing agent_type}"

sql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEAMS_DIR="$SCRIPT_DIR/../teams"

PROJECT_PATH_ESC=$(sql_escape "$PROJECT_PATH")
AGENT_TYPE_ESC=$(sql_escape "$AGENT_TYPE")

[ -d "$TEAMS_DIR" ] || exit 0

for config_file in "$TEAMS_DIR"/*/config.json; do
  [ -f "$config_file" ] || continue
  CONFIG_FILE_ESC=$(sql_escape "$config_file")
  TEAM_NAME=$(sqlite3 :memory: "
    SELECT json_extract(readfile('$CONFIG_FILE_ESC'), '\$.name');
  ")
  [ -z "$TEAM_NAME" ] && continue
  [ "$TEAM_NAME" = "null" ] && continue

  TEAM_NAME_ESC=$(sql_escape "$TEAM_NAME")
  PROJECT_JSON_ESC=$(sqlite3 :memory: "SELECT json_quote('$PROJECT_PATH_ESC');" | sed "s/'/''/g")
  AGENT_TYPE_JSON_ESC=$(sqlite3 :memory: "SELECT json_quote('$AGENT_TYPE_ESC');" | sed "s/'/''/g")

  sqlite3 -separator $'\t' :memory: "
    WITH agents AS (
      SELECT
        key AS name,
        CASE
          WHEN json_type(value, '\$.registrations') = 'array' THEN json_extract(value, '\$.registrations')
          ELSE json_array(json_object(
            'type', json_extract(value, '\$.type'),
            'project', json_extract(value, '\$.project')
          ))
        END AS registrations
      FROM json_each(readfile('$CONFIG_FILE_ESC'), '\$.agents')
    )
    SELECT DISTINCT '$TEAM_NAME_ESC' AS team, name
    FROM agents, json_each(agents.registrations) AS r
    WHERE json_extract(r.value, '\$.project') = json_extract('$PROJECT_JSON_ESC', '\$')
      AND json_extract(r.value, '\$.type') = json_extract('$AGENT_TYPE_JSON_ESC', '\$')
    ORDER BY team, name;
  "
done
