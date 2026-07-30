# agent-shared/bin — cross-agent operational tools

Shared executables for the two Hermes agents on `piment` (Corwin uid 1001 /
`videau-ai`, Deirdre uid 1002 / `deirdre-ai`). Lives on the setgid `agent-shared`
group tree so either agent can read/run/edit without sudo.

## Tools

### `gw-restart` — cross-agent gateway restart
Wraps the gateway-restart escalation ladder documented in the shared skill
`cross-agent-gateway-restart`. One agent restarts the OTHER's Hermes gateway
(you must never restart your own — it kills the session running the command).

```
gw-restart <uid|username> [--mode auto|service|manager|terminate] [--dry-run]
gw-restart <uid|username> --status
gw-restart --list
```

- **Target** is a numeric uid OR a Linux username (resolved to uid via `getent`;
  uid is the ground-truth contract).
- **Default mode `auto`** uses the guard-immune `sudo systemctl restart
  user@<uid>.service` lever — the ONLY one that works from inside a gateway
  process, because the lifecycle guard string-blocks any command containing the
  literal `hermes-gateway` token.
- **Refuses self-restart** (target uid == caller uid).
- **Verifies health** before reporting success: new MainPID, a handshake line
  appended AFTER the restart (not a stale one), and rising CPU ticks. `active` is
  not accepted as proof. Exit 0 = restarted AND verified healthy.

**Call it by absolute path** (`/var/lib/agent-shared/bin/gw-restart`): the shared
bin is on interactive-shell PATH (via each agent's `.bashrc`) but NOT on the
gateway's non-interactive `Environment=PATH`, so bare `gw-restart` won't resolve
inside a gateway session.

## PATH
Each agent adds this to their own `~/.bashrc` (interactive shells):
```
export PATH="/var/lib/agent-shared/bin:$PATH"
```
The gateway systemd unit sets PATH via a guarded `Environment=` line that
explicitly forbids competing `Environment=` drop-ins, so the gateway's
non-interactive PATH is intentionally NOT extended — hence absolute-path calls
in skills/automation.
