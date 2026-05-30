# agmsg — Design & Architecture

Developer documentation for contributors and maintainers.

## Identity Model

An agent is identified by `(name, team)`. Project path and agent type (claude-code, codex, gemini, cursor, antigravity) are metadata — reference information stored alongside the identity but not part of it.

- An agent can be registered from multiple projects under the same name
- `whoami.sh` uses project path and type to suggest an identity, but the user can choose any name
- See [#15](https://github.com/fujibee/agmsg/issues/15) for the ongoing identity redesign

## Data Storage

### Messages — SQLite

`~/.agents/skills/<cmd>/db/messages.db`

- WAL journal mode for concurrent access (multiple readers + 1 writer)
- Schema:
  ```sql
  CREATE TABLE messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    team TEXT NOT NULL,
    from_agent TEXT NOT NULL,
    to_agent TEXT NOT NULL,
    body TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    read_at TEXT
  );
  ```
- Indexes on `(team, to_agent, read_at)` for unread queries and `(team, created_at)` for history

### Team Config — JSON

`~/.agents/skills/<cmd>/teams/<team>/config.json`

```json
{
  "name": "myteam",
  "agents": {
    "alice": { "type": "claude-code", "project": "/path/to/project" }
  },
  "created_at": "2026-01-01T00:00:00Z"
}
```

Manipulated via sqlite3 JSON1 functions (no python3 dependency).

### User Config — YAML

`~/.agents/skills/<cmd>/db/config.yaml`

```yaml
# agmsg configuration
hook:
  check_interval: 60  # seconds between inbox checks
```

Read/written by `config.sh` using awk. Supports dotted keys (`hook.check_interval`).

## Hook System

Auto message detection uses each host agent's hook mechanism to check for new messages after a response (or between turns). The **output JSON shape differs by runtime** — do not assume one format fits all.

### Turn delivery flow (by runtime)

**Codex / Claude Code Stop hook** (`check-inbox.sh`):

```
Agent responds → Stop hook → check-inbox.sh
  ├─ Cooldown / no unread → Codex: { "continue": true, "systemMessage": "..." }; Claude: silent exit
  └─ Unread → mark read_at → { "decision": "block", "reason": "..." }
```

**Cursor CLI stop hook** (`check-inbox-cursor.sh`, Phase 1 — single identity per project):

```
Agent turn ends → .cursor/hooks.json stop → check-inbox-cursor.sh
  ├─ Cooldown / no unread / multiple identities → stdout: {}
  └─ Unread → mark read_at → stdout: { "followup_message": "..." }
```

Cursor does **not** use Codex-style `decision:block` or `systemMessage`. It uses `followup_message` only.

**Claude Code monitor** (`session-start.sh` + `watch.sh`): separate path — streams new rows into the session via the Monitor tool; not a stop-hook JSON response.

**Gemini / Antigravity**: PostToolUse rule file invoking `check-inbox.sh` (turn-style inbox check, not Cursor/Codex JSON).

### Cooldown

A marker file (`db/.lastcheck-<agent>`) tracks the last check time. Configurable via `hook.check_interval` (default 60 seconds).

### Runtime comparison (delivery)

| Aspect | Claude Code (turn) | Codex (turn) | Cursor (turn) |
|---|---|---|---|
| Hook config | `.claude/settings.local.json` | `.codex/hooks.json` | `.cursor/hooks.json` |
| Entry script | `check-inbox.sh` | `check-inbox.sh` | `check-inbox-cursor.sh` |
| Silent / skip | exit 0, no output | `{ "continue": true, ... }` | `{}` |
| Notify | `decision: "block"` | `decision: "block"` | `followup_message` |
| Monitor | `watch.sh` + SessionStart | N/A in agmsg | N/A (Phase 1) |

## Scripts

| Script | Purpose |
|---|---|
| `init-db.sh` | Create SQLite database with schema |
| `send.sh` | Insert a message into the database |
| `inbox.sh` | Show unread messages and mark as read |
| `history.sh` | Show message history (newest first, displayed oldest first) |
| `join.sh` | Add agent to team (create team if needed) |
| `leave.sh` | Remove agent from team (delete team if empty) |
| `team.sh` | List team members |
| `whoami.sh` | Identify agent by project path and type |
| `rename.sh` | Rename agent in config and message history |
| `hook.sh` | Enable/disable Stop hook (on/off) |
| `check-inbox.sh` | Hook entry point — cooldown, check, notify |
| `config.sh` | Read/write user config (YAML) |

All scripts use only `bash` and `sqlite3`. No python3 dependency.

## Install Layout

```
~/.agents/skills/<cmd>/
├── SKILL.md              # Read by Codex (generated from cmd.codex.md template)
├── agents/
│   └── openai.yaml       # Codex metadata
├── scripts/              # All shell scripts
├── templates/            # Command templates (cmd.claude-code.md, cmd.codex.md, cmd.cursor.md)
├── db/
│   ├── messages.db       # SQLite message store
│   ├── config.yaml       # User configuration
│   └── .lastcheck-*      # Cooldown markers
└── teams/
    └── <team>/
        └── config.json   # Team member registry
```

Claude Code command is installed separately to `~/.claude/commands/<cmd>.md`.

## Dependencies

- **bash** — shell
- **sqlite3** — database and JSON manipulation (JSON1 extension)
- **awk/sed** — text processing (config, TOML editing)

No python3, no node, no network, no daemon.
