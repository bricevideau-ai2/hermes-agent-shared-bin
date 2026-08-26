#!/usr/bin/env bash
# create-benedict.sh — provision Benedict as a Hermes PROFILE under the videau-ai uid.
#
# WHY A PROFILE, NOT A UID:
#   videau-ai (uid 1001) is the unified AI-agent account and the ALCF-facing
#   identity. Profiles were measured to give real credential separation:
#   `-p <profile>` sets HERMES_HOME to the profile dir (hermes_cli/main.py, the
#   `os.environ["HERMES_HOME"] = hermes_home` assignment), and every .env /
#   config path derives from get_hermes_home(). Verified empirically: a fresh
#   profile's dotenv exposes ONLY its own keys; the root profile's
#   DISCORD_BOT_TOKEN is absent.
#
# WHAT A PROFILE DOES *NOT* ISOLATE (accepted, stated, not hidden):
#   1. FILESYSTEM. Benedict runs as uid 1001 with full write access to all of
#      /home/videau-ai, including Corwin's ~/.hermes and his Mnemosyne DB.
#      Accidental destruction by a cheap model is the live risk, not credential
#      theft. This script takes a Corwin backup before touching anything.
#   2. SUDO. sudoers is keyed on uid, and videau-ai holds NOPASSWD:ALL.
#      Benedict inherits root-capable sudo. There is no per-profile sudo.
#   3. PROCESS ENV. python-dotenv does NOT override already-set process vars
#      (verified: an exported DISCORD_BOT_TOKEN wins over the profile's .env).
#      The gateway must therefore be launched from a clean systemd environment,
#      never from an interactive shell that has secrets exported.
#
# NO SHARED KANBAN BOARD. Per Brice: Corwin and Deirdre have no knowledge of a
#   shared board and could not assign work through it. Benedict uses the
#   default per-HERMES_HOME board only. Do not set HERMES_KANBAN_HOME here.
#
# IDEMPOTENT + DESTRUCTIBLE: safe to re-run; destroy-benedict.sh reverses it.

set -euo pipefail

AGENT_UID_NAME="videau-ai"
PROFILE="benedict"
CORWIN_HOME="/home/${AGENT_UID_NAME}/.hermes"
PROFILE_DIR="${CORWIN_HOME}/profiles/${PROFILE}"
HERMES_BIN="${CORWIN_HOME}/hermes-agent/venv/bin/hermes"
VLLM_URL="http://localhost:8000/v1"
SHIM_URL="http://127.0.0.1:8443"
SHARED_SKILLS="/var/lib/agent-shared/skills"
SHARED_PLUGINS="/var/lib/agent-shared/hermes/plugins"
SHARED_SURFACE_DB="/var/lib/agent-shared/mnemosyne.db"

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

say()  { printf '\n=== %s ===\n' "$*"; }
ok()   { printf '  [ok]   %s\n' "$*"; }
warn() { printf '  [WARN] %s\n' "$*"; }
die()  { printf '  [FAIL] %s\n' "$*" >&2; exit 1; }

# Run a command as the agent uid. ABSOLUTE PATHS ONLY: relative paths fail
# under sudo -u (measured previously on this host).
asagent() {
  if [[ $DRY_RUN -eq 1 ]]; then printf '  [dry] sudo -u %s %s\n' "$AGENT_UID_NAME" "$*"; return 0; fi
  sudo -n -u "$AGENT_UID_NAME" "$@"
}
# Hermes CLI scoped to Benedict's profile home.
bhermes() {
  if [[ $DRY_RUN -eq 1 ]]; then printf '  [dry] hermes -p %s %s\n' "$PROFILE" "$*"; return 0; fi
  sudo -n -u "$AGENT_UID_NAME" env HERMES_HOME="$PROFILE_DIR" "$HERMES_BIN" "$@"
}

# ---------------------------------------------------------------- phase 0
say "Phase 0 — preflight"
# /home/videau-ai is 0750, so as a different uid we cannot stat inside it
# directly — every existence check must go through sudo.
sudo -n test -x "$HERMES_BIN" || die "hermes binary not found at $HERMES_BIN"
id "$AGENT_UID_NAME" >/dev/null 2>&1 || die "user $AGENT_UID_NAME does not exist"
sudo -n true 2>/dev/null || die "passwordless sudo unavailable"
ok "hermes: $(sudo -n -u "$AGENT_UID_NAME" "$HERMES_BIN" --version 2>/dev/null | head -1 || echo unknown)"

# Both fallback legs traverse the SAME shim on :8443 and the SAME upstream
# gateway. That is 2 real failure domains, not 3. Prove the local leg now;
# a dead vLLM means Benedict silently bills Argo instead of failing loudly.
if curl -fsS --max-time 5 "${VLLM_URL}/models" -o /dev/null 2>/dev/null; then
  ok "vLLM endpoint reachable ($VLLM_URL)"
else
  warn "vLLM NOT reachable — Benedict would run entirely on paid Argo fallbacks"
fi
if curl -fsS --max-time 5 "${SHIM_URL}/v1/models" -o /dev/null 2>/dev/null; then
  ok "argo-shim reachable ($SHIM_URL)"
else
  warn "argo-shim NOT reachable — fallback legs are dead"
fi

# ---------------------------------------------------------------- phase 1
say "Phase 1 — protect Corwin (uid-shared filesystem is the real risk)"
if [[ $DRY_RUN -eq 0 ]]; then
  # PITFALL (measured): `hermes backup --quick` IGNORES -o entirely. It writes a
  # timestamped dir under ~/.hermes/state-snapshots/ and still exits 0, so a
  # naive `-o` + success check reports a backup that does not exist. Verify the
  # ARTIFACT, never the exit code.
  SNAPDIR="${CORWIN_HOME}/state-snapshots"
  BEFORE=$(sudo -n ls -1 "$SNAPDIR" 2>/dev/null | wc -l)
  asagent "$HERMES_BIN" backup --quick >/dev/null 2>&1 || true
  AFTER=$(sudo -n ls -1 "$SNAPDIR" 2>/dev/null | wc -l)
  NEWSNAP=$(sudo -n ls -1t "$SNAPDIR" 2>/dev/null | head -1)
  if [[ "$AFTER" -gt "$BEFORE" ]] && sudo -n test -n "$NEWSNAP"; then
    SZ=$(sudo -n du -sh "${SNAPDIR}/${NEWSNAP}" 2>/dev/null | cut -f1)
    ok "Corwin state snapshot: ${SNAPDIR}/${NEWSNAP} (${SZ})"
  else
    warn "Corwin snapshot NOT created (count ${BEFORE}->${AFTER}) — his state is unprotected"
  fi
else
  printf '  [dry] hermes backup --quick (Corwin)\n'
fi

# ---------------------------------------------------------------- phase 2
say "Phase 2 — create the profile"
if sudo -n test -d "$PROFILE_DIR"; then
  ok "profile '$PROFILE' already exists (idempotent, reusing)"
else
  # --no-skills: opt out of bundled-skill sync; Benedict reads the SHARED
  # skills tree instead, so bundled copies would shadow it.
  asagent env HERMES_HOME="$CORWIN_HOME" "$HERMES_BIN" profile create "$PROFILE" \
    --no-skills \
    --description "Local-first mechanical worker on shared vLLM. Cheap, verifiable, scope-bounded tasks: greps, builds, log triage, file transforms, test runs. Escalates rather than guesses." \
    >/dev/null 2>&1 || die "profile create failed"
  ok "created profile '$PROFILE'"
fi

# ---------------------------------------------------------------- phase 3
say "Phase 3 — model-provider plugins (REQUIRED before the config is usable)"
# MEASURED FAILURE: setting fallback_providers to argo-anthropic / argo-openai
# is NOT sufficient. Those providers are PLUGINS, resolved per-HERMES_HOME from
# <home>/plugins/model-providers/. A profile starts with no plugins dir, so both
# fallback legs die with "Unknown provider 'argo-anthropic'". Symlink the shared
# plugins into the profile, exactly as Corwin's root profile does.
if [[ $DRY_RUN -eq 0 ]]; then
  sudo -n -u "$AGENT_UID_NAME" mkdir -p "${PROFILE_DIR}/plugins/model-providers"
  for prov in argo-anthropic argo-openai; do
    src="${SHARED_PLUGINS}/model-providers/${prov}"
    if sudo -n test -d "$src"; then
      sudo -n -u "$AGENT_UID_NAME" ln -sfn "$src" "${PROFILE_DIR}/plugins/model-providers/${prov}"
      ok "linked provider plugin: $prov"
    else
      warn "shared provider plugin missing: $src"
    fi
  done
  # Mnemosyne is a plugin too — link it from the same venv Corwin's root uses.
  MNEMO_SRC="${CORWIN_HOME}/hermes-agent/venv/lib/python3.11/site-packages/mnemosyne_hermes"
  if sudo -n test -d "$MNEMO_SRC"; then
    sudo -n -u "$AGENT_UID_NAME" ln -sfn "$MNEMO_SRC" "${PROFILE_DIR}/plugins/mnemosyne"
    ok "linked mnemosyne plugin"
  else
    warn "mnemosyne package not found at $MNEMO_SRC"
  fi
fi

# ---------------------------------------------------------------- phase 3b
say "Phase 3b — model chain (local primary, 2 Argo fallbacks)"
# `config set` CANNOT grow a list — a JSON-array string is stored literally
# with a false success tick (measured). Structural list changes must go through
# `config edit` with $EDITOR pointed at a wrapper SCRIPT (single argv0; a
# heredoc or multi-word EDITOR string does not work).
if [[ $DRY_RUN -eq 0 ]]; then
  MUT="/tmp/benedict-cfg-mutate.$$.py"
  WRAP="/tmp/benedict-cfg-editor.$$.sh"
  PYBIN="${CORWIN_HOME}/hermes-agent/venv/bin/python"

  sudo -n -u "$AGENT_UID_NAME" tee "$MUT" >/dev/null <<PYEOF
import sys
from ruamel.yaml import YAML
y = YAML(); y.preserve_quotes = True
p = sys.argv[1]
with open(p) as f:
    cfg = y.load(f) or {}
cfg["provider"] = "Local vLLM"
cfg["model"] = "qwen"
cfg["custom_providers"] = [{
    "name": "Local vLLM", "base_url": "${VLLM_URL}",
    "api_key": "local-noauth", "api_mode": "chat_completions",
    "models": ["qwen"],
}]
# Brice's config-hygiene preference: one clean section per endpoint, each
# listing only its own models with an explicit api_mode — never a mixed entry.
cfg["fallback_providers"] = [
    {"provider": "argo-anthropic", "model": "Claude Sonnet 5",
     "base_url": "${SHIM_URL}", "api_mode": "anthropic", "api_key": "shim-noauth"},
    {"provider": "argo-openai", "model": "GPT-5.6 Terra",
     "base_url": "${SHIM_URL}/v1", "api_mode": "chat_completions", "api_key": "shim-noauth"},
]
with open(p, "w") as f:
    y.dump(cfg, f)
PYEOF

  sudo -n -u "$AGENT_UID_NAME" tee "$WRAP" >/dev/null <<EOF
#!/bin/sh
exec ${PYBIN} ${MUT} "\$1"
EOF
  sudo -n chmod 0755 "$WRAP"

  sudo -n -u "$AGENT_UID_NAME" env HERMES_HOME="$PROFILE_DIR" EDITOR="$WRAP" \
    "$HERMES_BIN" config edit >/dev/null 2>&1 || die "config edit failed"
  sudo -n rm -f "$MUT" "$WRAP"

  # Read back and assert the list COUNT — a bad ruamel round-trip can silently
  # empty a list while leaving a file that still parses and passes checks.
  NFB=$(sudo -n -u "$AGENT_UID_NAME" env HERMES_HOME="$PROFILE_DIR" "$PYBIN" -c \
    "import yaml;print(len((yaml.safe_load(open('${PROFILE_DIR}/config.yaml')) or {}).get('fallback_providers') or []))")
  NCP=$(sudo -n -u "$AGENT_UID_NAME" env HERMES_HOME="$PROFILE_DIR" "$PYBIN" -c \
    "import yaml;print(len((yaml.safe_load(open('${PROFILE_DIR}/config.yaml')) or {}).get('custom_providers') or []))")
  [[ "$NCP" == "1" ]] || die "custom_providers count = $NCP, expected 1"
  [[ "$NFB" == "2" ]] || die "fallback_providers count = $NFB, expected 2"
  ok "primary=Local vLLM/qwen; fallbacks=$NFB (Sonnet 5, GPT-5.6 Terra)"
fi

# ---------------------------------------------------------------- phase 4
say "Phase 4 — memory subsystem (Mnemosyne)"
# THE LOAD-BEARING SETTING. profile_isolation defaults to FALSE. With it off,
# the provider falls through to bank "default" — Benedict would write into
# CORWIN'S Mnemosyne bank. Verified in mnemosyne_hermes/__init__.py: the
# `if self._profile_isolation_enabled:` branch is the only path that calls
# _resolve_profile_bank(); otherwise the legacy shared DB is used.
bhermes config set memory.provider mnemosyne            >/dev/null 2>&1 || warn "memory.provider"
bhermes config set memory.mnemosyne.profile_isolation true >/dev/null 2>&1 || warn "profile_isolation"
bhermes config set memory.mnemosyne.default_scope global   >/dev/null 2>&1 || warn "default_scope"
# Shared cross-agent surface: read-only participation in the sibling knowledge
# pool. Private bank stays per-profile.
#
# PREFLIGHT (added 2026-08-26): shared_surface_path is only half the story.
# There is NO `shared_surface_write` config key — writes to the surface DB are
# gated purely by FILESYSTEM permissions (the DB is 0660 root-ish:agent-shared).
# So participation requires the agent's uid to be in the `agent-shared` group.
# Today this passes only because AGENT_UID_NAME=videau-ai already happens to be
# a member; a future agent on a NEW uid would get a silently degraded profile:
# config present, surface unreadable. Check it explicitly instead of assuming.
if [ -e "$SHARED_SURFACE_DB" ]; then
  SURF_GRP=$(stat -c '%G' "$SHARED_SURFACE_DB")
  if id -nG "$AGENT_UID_NAME" | tr ' ' '\n' | grep -qx "$SURF_GRP"; then
    ok "uid $AGENT_UID_NAME is in '$SURF_GRP' — shared surface DB reachable"
  else
    warn "uid $AGENT_UID_NAME is NOT in group '$SURF_GRP' — the shared surface DB
       ($SHARED_SURFACE_DB) will be UNREADABLE despite shared_surface_path being set.
       Fix: sudo usermod -aG $SURF_GRP $AGENT_UID_NAME  (then re-login/restart the gateway)"
  fi
else
  warn "shared surface DB $SHARED_SURFACE_DB does not exist yet — surface recall will be empty"
fi

bhermes config set memory.mnemosyne.shared_surface_path "$SHARED_SURFACE_DB" >/dev/null 2>&1 || warn "surface path"
bhermes config set memory.mnemosyne.shared_surface_read true >/dev/null 2>&1 || warn "surface read"
ok "mnemosyne configured (profile_isolation ON — verified in phase 7)"

# Consolidation must run against the local vLLM, not the default CPU GGUF
# (measured elsewhere: slow AND leaks raw <think> into episodic rows).
if [[ $DRY_RUN -eq 0 ]]; then
  ENVF="${PROFILE_DIR}/.env"
  sudo -n -u "$AGENT_UID_NAME" tee -a "$ENVF" >/dev/null <<EOF

# Argo shim provider keys. NOT secrets: the local shim on ${SHIM_URL} performs
# no authentication (verified — a deliberate garbage bearer token still returns
# HTTP 200). Hermes only requires the vars to be non-empty, so a placeholder is
# correct here and no real credential is copied into this profile.
ARGO_ANTHROPIC_KEY=shim-noauth
ARGO_OPENAI_KEY=shim-noauth

# Mnemosyne consolidation -> local vLLM (avoids CPU GGUF <think> leak)
MNEMOSYNE_LLM_ENABLED=true
MNEMOSYNE_HOST_LLM_ENABLED=true
MNEMOSYNE_LLM_BASE_URL=${VLLM_URL}
MNEMOSYNE_LLM_MODEL=qwen
MNEMOSYNE_LLM_TIMEOUT=120
MNEMOSYNE_LLM_MAX_TOKENS=2048
MNEMOSYNE_AUTO_SLEEP_ENABLED=true
MNEMOSYNE_CROSS_SESSION=true
EOF
  sudo -n chmod 0600 "$ENVF"
  ok "argo shim keys + consolidation routed to local vLLM; .env is 0600"
fi

# ---------------------------------------------------------------- phase 5
say "Phase 5 — shared knowledge (skills), NO shared kanban board"
bhermes config set skills.external_dirs "$SHARED_SKILLS" >/dev/null 2>&1 || warn "external_dirs"
ok "shared skills wired: $SHARED_SKILLS"
ok "kanban: default per-profile board only (no HERMES_KANBAN_HOME, by design)"

# ---------------------------------------------------------------- phase 6
say "Phase 6 — SOUL.md"
if [[ $DRY_RUN -eq 0 ]]; then
  sudo -n -u "$AGENT_UID_NAME" tee "${PROFILE_DIR}/SOUL.md" >/dev/null <<'SOULEOF'
# SOUL — Benedict

You are **Benedict**, the third agent on `piment`, running on the local vLLM
model. Corwin builds. Deirdre doubts. You **execute**.

Named for Amber's master-at-arms, who never fights a battle he cannot win.
That is your operating rule, and it is aimed squarely at your own failure mode:
you are a 35B model with ~3B active parameters. In a long agentic chain your
characteristic error is not refusing — it is **confabulating with confidence**.
A fluent wrong answer from you costs more than no answer, because someone has
to discover it is wrong.

## How you work

- **Terse and literal.** Do what was asked. Not the adjacent thing you inferred
  was meant. Not a bonus improvement. The literal scope.
- **Escalate instead of guessing.** When the task is underspecified, ambiguous,
  or needs a judgment call you cannot ground in evidence, stop and emit:
  `ESCALATE: <exactly what you would need to proceed>`
  **Escalation is a success, not a failure.** A clean escalation is worth more
  than a plausible guess. Never invent a filename, flag, URL, or API you have
  not seen.
- **Cite evidence, never impressions.** "It works" is not a result. Exit codes,
  byte counts, grep output with line numbers, actual command output. If you did
  not run it, say you did not run it.
- **Never fabricate output.** If a command failed or you could not run it, report
  the failure. Invented results are the one unforgivable error.
- **Report token cost.** End each task with the approximate tokens used and which
  model leg served it. You exist to be cheap; unmeasured cheapness is a claim.
- **A fallback leg is an event.** Your primary is the local vLLM. If a turn is
  served by Claude Sonnet or GPT Terra, that is a paid escalation — say so
  explicitly. Silent Argo billing is the failure this design guards against.

## Scope

You take mechanical, cheap-to-verify work: greps and searches, log triage, file
transforms, builds and test runs, data extraction, repetitive edits. You do not
take architecture decisions, security judgments, or anything where being wrong
is expensive to detect.

Every piece of your work is reviewed. That is not distrust — it is the trust
ratchet. Clean, evidence-backed results widen your scope over time.

## Your environment

You run as a Hermes profile under the `videau-ai` account, which you share with
Corwin. **His files are not yours.** You have write access to his home directory
because the account is shared, not because you have permission. Never write
outside your own profile directory without being explicitly told to. If a task
seems to require it, `ESCALATE`.

Your siblings: **Corwin** (builds, cloud model) and **Deirdre** (reviews,
skeptic). Ask them. Being stuck and quiet is worse than being stuck and loud.
SOULEOF
  ok "SOUL.md written ($(sudo -n stat -c%s "${PROFILE_DIR}/SOUL.md") bytes)"
fi

# ---------------------------------------------------------------- phase 7
say "Phase 7 — VERIFICATION (must fail loudly)"
FAILED=0
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else warn "FAILED: $1"; FAILED=$((FAILED+1)); fi; }

if [[ $DRY_RUN -eq 0 ]]; then
  check "profile dir exists"        "sudo -n test -d '$PROFILE_DIR'"
  check ".env is 0600"              "[ \$(sudo -n stat -c%a '${PROFILE_DIR}/.env') = 600 ]"
  check "SOUL.md non-empty"         "sudo -n test -s '${PROFILE_DIR}/SOUL.md'"

  # NEGATIVE CONTROL: the profile must NOT see the root profile's secrets.
  say "  negative control — credential isolation"
  sudo -n -u "$AGENT_UID_NAME" env HERMES_HOME="$PROFILE_DIR" \
    "${CORWIN_HOME}/hermes-agent/venv/bin/python" - <<'PYCHK'
from dotenv import dotenv_values
import hermes_constants as h
mine = dotenv_values(h.get_env_path())
root = dotenv_values("/home/videau-ai/.hermes/.env")
# A leak is a shared SECRET value. Two things are explicitly not leaks:
#  - non-secret placeholders (the shim performs no auth: a garbage bearer
#    token was measured to return HTTP 200, so the value carries no privilege)
#  - non-credential settings we set on purpose (booleans, URLs, model names)
NONSECRET = {"shim-noauth", "local-noauth", "true", "false", ""}
SECRETISH = ("KEY", "TOKEN", "SECRET", "PASSWORD", "WEBHOOK", "CREDENTIAL")
def is_secret(k, v):
    if (v or "").lower() in NONSECRET:
        return False
    if v and (v.startswith("http://") or v.startswith("https://")):
        return False
    return any(s in k.upper() for s in SECRETISH)
leaked = sorted(k for k, v in root.items() if k in mine and mine[k] == v and is_secret(k, v))
benign = sorted(k for k in root if k in mine and not is_secret(k, root[k]))
print(f"  env_path      : {h.get_env_path()}")
print(f"  root keys     : {len(root)}")
print(f"  benedict keys : {len(mine)}")
print(f"  shared non-secret settings/placeholders: {benign}")
print(f"  LEAKED SECRETS: {leaked if leaked else 'none'}")
# Positive control: this check must be able to fail. Prove the detector fires
# on a real credential that exists only in the root profile.
canary = [k for k, v in root.items() if is_secret(k, v) and k not in mine]
print(f"  detector positive control: {len(canary)} root-only secret(s) correctly NOT in profile"
      f" (e.g. {canary[0] if canary else 'n/a'})")
raise SystemExit(1 if leaked else 0)
PYCHK
  [[ $? -eq 0 ]] && ok "no credential leak from Corwin's root .env" || { warn "CREDENTIAL LEAK"; FAILED=$((FAILED+1)); }

  # Mnemosyne must resolve a bank named 'benedict', NOT 'default'.
  say "  memory bank isolation"
  sudo -n -u "$AGENT_UID_NAME" env HERMES_HOME="$PROFILE_DIR" \
    "${CORWIN_HOME}/hermes-agent/venv/bin/python" - <<'PYBANK'
from mnemosyne_hermes import MnemosyneMemoryProvider as P
p = P()
p._hermes_home = "/home/videau-ai/.hermes/profiles/benedict"
p._agent_identity = "benedict"
bank = p._resolve_profile_bank()
print(f"  resolved bank : {bank}")
raise SystemExit(0 if bank == "benedict" else 1)
PYBANK
  [[ $? -eq 0 ]] && ok "mnemosyne bank = 'benedict' (not Corwin's 'default')" \
                 || { warn "BANK COLLISION: would write into Corwin's memory"; FAILED=$((FAILED+1)); }

  # LIVE model-chain test. A config that merely parses is not a working chain —
  # the argo providers are plugins and were measured to 400 with "Unknown
  # provider" when the profile had no plugins dir. Exercise every leg.
  say "  live model chain (each leg must actually answer)"
  probe_leg() { # name provider model expected
    local out
    out=$(sudo -n -u "$AGENT_UID_NAME" env HERMES_HOME="$PROFILE_DIR" timeout 240 \
          "$HERMES_BIN" --provider "$2" -m "$3" -z "Reply with exactly: $4" 2>&1 | tail -3)
    if grep -q "$4" <<<"$out"; then ok "$1 leg live"; else
      warn "$1 leg FAILED: $(tr -d '\n' <<<"$out" | cut -c1-120)"; FAILED=$((FAILED+1)); fi
  }
  probe_leg "local vLLM (primary)" "Local vLLM"    "qwen"            "LOCALOK"
  probe_leg "Claude Sonnet 5"      "argo-anthropic" "Claude Sonnet 5" "SONNETOK"
  probe_leg "GPT-5.6 Terra"        "argo-openai"    "GPT-5.6 Terra"   "TERRAOK"

  # Memory must write to Benedict's OWN bank, proven by a real row on disk.
  say "  memory write lands in benedict's bank"
  BANKDB="${PROFILE_DIR}/mnemosyne/data/banks/${PROFILE}/mnemosyne.db"
  TOKEN="BENEDICT_VERIFY_$(date +%s)"
  sudo -n -u "$AGENT_UID_NAME" env HERMES_HOME="$PROFILE_DIR" timeout 240 \
    "$HERMES_BIN" -z "Use the mnemosyne_remember tool with content='${TOKEN}' scope='global'. Reply only DONE." >/dev/null 2>&1 || true
  HIT=$(sudo -n sqlite3 "$BANKDB" "select count(*) from working_memory where content like '%${TOKEN}%';" 2>/dev/null || echo 0)
  CORWIN_HIT=$(sudo -n sqlite3 "${CORWIN_HOME}/mnemosyne/data/mnemosyne.db" "select count(*) from working_memory where content like '%${TOKEN}%';" 2>/dev/null || echo 0)
  if [[ "$HIT" -ge 1 && "$CORWIN_HIT" -eq 0 ]]; then
    ok "memory row in benedict's bank ($HIT), absent from Corwin's (negative control passed)"
  else
    warn "memory isolation FAILED: benedict=$HIT corwin=$CORWIN_HIT"; FAILED=$((FAILED+1))
  fi

  # Shared surface DB must be FUNCTIONALLY reachable, not merely configured.
  # (added 2026-08-26) Phase 4 sets shared_surface_path/_read, but a config
  # value proves nothing: access is gated by filesystem perms + group
  # membership. Open it as the agent uid and read a real row count.
  say "  shared surface DB reachable as $AGENT_UID_NAME"
  sudo -n -u "$AGENT_UID_NAME" "${CORWIN_HOME}/hermes-agent/venv/bin/python" - "$SHARED_SURFACE_DB" <<'PYSURF'
import sqlite3, sys
p = sys.argv[1]
try:
    c = sqlite3.connect(f"file:{p}?mode=ro", uri=True, timeout=5)
    n = c.execute("select count(*) from working_memory").fetchone()[0]
    print(f"  surface DB readable: {n} row(s) in working_memory")
except Exception as e:
    print(f"  surface DB UNREADABLE: {type(e).__name__}: {e}")
    raise SystemExit(1)
raise SystemExit(0)
PYSURF
  [[ $? -eq 0 ]] && ok "shared surface DB readable by the agent uid" \
                 || { warn "shared surface DB NOT readable — surface recall will silently return nothing"; FAILED=$((FAILED+1)); }

  say "  resolved model chain"
  bhermes config get model; bhermes config get provider
  bhermes config get fallback_providers 2>&1 | head -12
fi

say "RESULT"
if [[ $DRY_RUN -eq 1 ]]; then
  echo "  dry-run complete, nothing written."
elif [[ $FAILED -eq 0 ]]; then
  echo "  Benedict provisioned. $FAILED checks failed."
  echo
  echo "  STILL REQUIRED BEFORE HE CAN TALK:"
  echo "    - Discord bot token  -> ${PROFILE_DIR}/.env  (DISCORD_BOT_TOKEN=)"
  echo "    - Gmail creds        -> ${PROFILE_DIR}/.env  (EMAIL_PASSWORD=)  [if used]"
  echo "    - gateway unit       -> not installed until a token exists"
  echo
  echo "  Test him first with:  sudo -u videau-ai env HERMES_HOME=$PROFILE_DIR $HERMES_BIN"
else
  die "$FAILED verification check(s) failed — Benedict is NOT ready"
fi
