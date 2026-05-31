---
name: __SKILL_NAME__
description: Cross-agent messaging via SQLite for Cursor CLI. Send messages between Claude Code, Codex, Gemini CLI, Cursor, and other agents.
---

Agent messaging for **Cursor CLI** (`cursor-agent`). **IMPORTANT: Always use the provided scripts. NEVER directly read or edit config files, DB, or team data. There is NO register.sh — use join.sh to join a team.**

Cursor supports **manual inbox** and **turn** delivery only. Cursor does not use Codex-style `decision:block` or `systemMessage` JSON — turn mode uses `.cursor/hooks.json` `stop` hooks, `.cursor/rules/agmsg.mdc` guidance, and `followup_message`.

If this command or skill is missing, install agmsg from the repository:

```bash
./install.sh --cmd __SKILL_NAME__
```

Then restart Cursor or reload its rules/skills.

## Identity

Run: `~/.agents/skills/__SKILL_NAME__/scripts/whoami.sh "$(pwd)" cursor`

Four possible outputs (same semantics as other agents):

**A) Single identity:** `agent=<name> teams=<t1,t2,...> type=cursor project=<path>` → Remember AGENT and TEAMS.

**B) Multiple identities:** `multiple=true agents=<n1,n2,...> teams=<t1,t2,...> type=cursor project=<path>` → Cursor turn hooks assume a **single** identity; `check-inbox-cursor.sh` returns `{}` until you use one agent name per project (e.g. leave one team or rename).

**C) Not in a team:** `not_joined=true available_teams=...` → Prompt for team and agent name, then:
`~/.agents/skills/__SKILL_NAME__/scripts/join.sh <team> <agent_name> cursor "$(pwd)"`

After joining, ask for delivery mode (Cursor supports **turn** and **off** only):

```
Choose delivery mode for incoming messages:

  1) turn — Check inbox at the end of each assistant turn (stop hook + followup_message)
  2) off  — No automatic delivery; manual checks only

[1]:
```

Map `1`→`turn`, `2`→`off`, then:
`~/.agents/skills/__SKILL_NAME__/scripts/delivery.sh set <mode> cursor "$(pwd)"`

**D) Suggestions:** `suggest=true ...` → Offer reuse of an existing agent name, then join as above.

## Manual operations

Only use scripts under `~/.agents/skills/__SKILL_NAME__/scripts/`:

| Action | Command |
|--------|---------|
| Whoami | `whoami.sh "$(pwd)" cursor` |
| Inbox | `inbox.sh <team> <agent>` |
| Send | `send.sh <team> <from> <to> "<message>"` |
| History | `history.sh <team> [agent] [limit]` |
| Team | `team.sh <team>` |

**Default (no subcommand):** run inbox for each TEAM immediately — do not ask what to do first.

## Delivery modes (Cursor)

| Mode | Supported |
|------|-----------|
| `turn` | Yes — `.cursor/hooks.json` `hooks.stop[]` runs `check-inbox-cursor.sh`; returns `followup_message` when unread |
| `off` | Yes — manual only |
| `monitor` | **No** — not available on Cursor CLI |
| `both` | **No** |

Set mode: `delivery.sh set <turn|off> cursor "$(pwd)"`  
Status: `delivery.sh status cursor "$(pwd)"`

**Notes:**
- For Cursor, turn mode uses both `.cursor/hooks.json` for stop-hook delivery and `.cursor/rules/agmsg.mdc` for always-on guidance.
- Turn mode requires a **single** `(project, cursor)` identity; multiple agents on the same project disable automatic inbox checks (`{}`).
- Turn mode targets **interactive** `cursor-agent`. Headless `cursor-agent --print` may not fire `stop` hooks.
- `delivery.sh set turn cursor "$(pwd)"` manages `<project>/.cursor/hooks.json` and `<project>/.cursor/rules/agmsg.mdc`.
- `delivery.sh set off cursor "$(pwd)"` removes the hook but leaves the rule for manual guidance.
- Git-backed workspaces are recommended for project hooks/rules.
- Hook stdin may contain `user_email` — never log or persist hook stdin JSON.

## Subcommands

If argument is `history` → `history.sh $TEAM $AGENT`  
If argument is `team` → `team.sh $TEAM` for each TEAM  
If argument starts with `send` → `send.sh $TEAM $AGENT <to> "<message>"`  
If argument is `mode` → `delivery.sh status cursor "$(pwd)"`  
If argument is `mode <turn|off>` → `delivery.sh set <mode> cursor "$(pwd)"` (reject `monitor` / `both`)  
If argument is `reset` → `reset.sh "$(pwd)" cursor`  
If argument is `config` / `config set` → use `config.sh` as for other agents

Legacy: `hook on` / `hook off` → `delivery.sh set turn|off cursor "$(pwd)"`
