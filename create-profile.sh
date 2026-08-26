#!/usr/bin/env bash
# create-profile.sh — provision an arbitrary Hermes agent as a PROFILE under a
# shared uid on this host. Generalized from create-benedict.sh (2026-08-26).
#
#   usage: create-profile.sh <agent-name> <soul-file> [options]
#
# WHY A PROFILE, NOT A UID:
#   The agent uid (default: videau-ai) is the unified AI-agent account and the
#   ALCF-facing identity. Profiles were measured to give real credential
#   separation: `-p <profile>` sets HERMES_HOME to the profile dir
#   (hermes_cli/main.py, the `os.environ["HERMES_HOME"] = hermes_home`
#   assignment), and every .env / config path derives from get_hermes_home().
#   Verified empirically: a fresh profile's dotenv exposes ONLY its own keys;
#   the root profile's DISCORD_BOT_TOKEN is absent.
#
# WHAT A PROFILE DOES *NOT* ISOLATE (accepted, stated, not hidden):
#   1. FILESYSTEM. The new agent runs as the shared uid with full write access
#      to that uid's whole home, including the ROOT profile's ~/.hermes and its
#      Mnemosyne DB, and to every SIBLING profile. Accidental destruction by a
#      cheap model is the live risk, not credential theft. This script takes a
#      root-profile backup before touching anything.
#   2. SUDO. sudoers is keyed on uid. If the shared uid holds NOPASSWD:ALL, the
#      new agent inherits root-capable sudo. There is no per-profile sudo.
#   3. PROCESS ENV. python-dotenv does NOT override already-set process vars
#      (verified: an exported DISCORD_BOT_TOKEN wins over the profile's .env).
#      The gateway must therefore be launched from a clean systemd environment,
#      never from an interactive shell that has secrets exported.
#
# NO SHARED KANBAN BOARD by default. The board is per-HERMES_HOME; agents that
#   don't know about a shared board cannot assign work through it. Opt in with
#   --kanban-home <dir> only when every participant knows it exists.
#
# IDEMPOTENT: safe to re-run against an existing profile.
#
# GENERALIZATION NOTES (what was hardcoded in create-benedict.sh and is now
# derived — each of these was a real portability bug, not a cosmetic rename):
#   - profile name appeared 28x, including INSIDE single-quoted heredocs where
#     shell expansion does not happen; those now receive the name via argv/env.
#   - python3.11 was hardcoded in the mnemosyne plugin path; now globbed from
#     the venv, because a venv rebuild on a new interpreter silently broke it.
#   - the root profile's .env path and the mnemosyne bank assertion embedded
#     /home/videau-ai literals; now derived from --uid.
#   - the bank check compared against the raw name, but the plugin SANITIZES
#     bank names ([a-z0-9_-], must start alphanumeric). An agent named "Foo.Bar"
#     would have failed a correct config. We now compare against the sanitized
#     value computed by the plugin itself.

set -euo pipefail

# ------------------------------------------------------------------ defaults
AGENT_UID_NAME="videau-ai"
VLLM_URL="http://localhost:8000/v1"
SHIM_URL="http://127.0.0.1:8443"
SHARED_ROOT="/var/lib/agent-shared"
SHARED_SKILLS=""            # derived from SHARED_ROOT unless overridden
SHARED_PLUGINS=""
SHARED_SURFACE_DB=""
PRIMARY_MODEL="qwen"
PRIMARY_PROVIDER="Local vLLM"
DESCRIPTION=""
KANBAN_HOME=""
DRY_RUN=0
SKIP_LIVE=0
PROFILE=""
SOUL_FILE=""

usage() {
  cat <<USAGE
usage: $(basename "$0") <agent-name> <soul-file> [options]

  <agent-name>   profile name; lowercase alphanumeric (becomes the Mnemosyne
                 bank name and the profile directory)
  <soul-file>    path to the SOUL.md content for this agent, or '-' to read
                 stdin. The file is REQUIRED: an agent with no soul is a
                 misconfiguration, not a default.

options:
  --uid <name>            unix account to host the profile   (default: $AGENT_UID_NAME)
  --description <text>    role blurb used by the kanban decomposer
  --model <name>          primary model                      (default: $PRIMARY_MODEL)
  --provider <name>       primary provider                   (default: $PRIMARY_PROVIDER)
  --vllm-url <url>        local OpenAI-compatible endpoint    (default: $VLLM_URL)
  --shim-url <url>        argo-shim base url                  (default: $SHIM_URL)
  --shared-root <dir>     shared skills/plugins/surface root  (default: $SHARED_ROOT)
  --kanban-home <dir>     opt in to a shared kanban board     (default: per-profile)
  --skip-live-checks      skip model/memory probes that spend tokens and time
  --dry-run               print what would happen, write nothing
  -h, --help              this text
USAGE
}

# ------------------------------------------------------------------ args
[[ $# -eq 0 ]] && { usage; exit 1; }
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --uid)             AGENT_UID_NAME="$2"; shift 2 ;;
    --uid=*)           AGENT_UID_NAME="${1#*=}"; shift ;;
    --description)     DESCRIPTION="$2"; shift 2 ;;
    --description=*)   DESCRIPTION="${1#*=}"; shift ;;
    --model)           PRIMARY_MODEL="$2"; shift 2 ;;
    --model=*)         PRIMARY_MODEL="${1#*=}"; shift ;;
    --provider)        PRIMARY_PROVIDER="$2"; shift 2 ;;
    --provider=*)      PRIMARY_PROVIDER="${1#*=}"; shift ;;
    --vllm-url)        VLLM_URL="$2"; shift 2 ;;
    --vllm-url=*)      VLLM_URL="${1#*=}"; shift ;;
    --shim-url)        SHIM_URL="$2"; shift 2 ;;
    --shim-url=*)      SHIM_URL="${1#*=}"; shift ;;
    --shared-root)     SHARED_ROOT="$2"; shift 2 ;;
    --shared-root=*)   SHARED_ROOT="${1#*=}"; shift ;;
    --kanban-home)     KANBAN_HOME="$2"; shift 2 ;;
    --kanban-home=*)   KANBAN_HOME="${1#*=}"; shift ;;
    --skip-live-checks) SKIP_LIVE=1; shift ;;
    --dry-run)         DRY_RUN=1; shift ;;
    -h|--help)         usage; exit 0 ;;
    -*)                echo "unknown option: $1" >&2; usage; exit 1 ;;
    *)                 POSITIONAL+=("$1"); shift ;;
  esac
done
set -- "${POSITIONAL[@]:-}"
PROFILE="${1:-}"
SOUL_FILE="${2:-}"

[[ -n "$PROFILE"   ]] || { echo "error: <agent-name> is required" >&2; usage; exit 1; }
[[ -n "$SOUL_FILE" ]] || { echo "error: <soul-file> is required (use '-' for stdin)" >&2; usage; exit 1; }

# The profile name becomes a directory AND a Mnemosyne bank name.
#
# NORMALIZE, DON'T REJECT (aligned with Hermes 2026-08-26). Hermes itself
# accepts mixed case and DOWNCASES it: hermes_cli/profiles.py
# normalize_profile_name() lowercases (and case-folds the `default` alias),
# then validate_profile_name() checks the result against
# ^[a-z0-9][a-z0-9_-]{0,63}$. Mnemosyne's _sanitize_bank_name() lowercases too.
# An earlier version of this script rejected any uppercase name outright,
# which was STRICTER THAN THE PLATFORM and would have refused a name that
# `hermes profile create` accepts. Measured: 'Testcap' -> 'testcap',
# 'DEIRDRE' -> 'deirdre', '  Spaced  ' -> 'spaced'.
#
# We normalize the same way, then tell the user when the name changed, so the
# soul says "Testcap" while the directory, bank, and systemd unit all agree on
# "testcap" — silent divergence between what you typed and what exists on disk
# is the actual failure mode here.
AGENT_INPUT="$PROFILE"
PROFILE="$(printf '%s' "$PROFILE" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
if [[ "$PROFILE" != "$AGENT_INPUT" ]]; then
  printf "  [note] agent name normalized: '%s' -> '%s' (Hermes stores profiles lowercase)\n" \
    "$AGENT_INPUT" "$PROFILE"
fi

# Leading DIGIT is legal in Hermes ([a-z0-9] start), so do not forbid it.
if ! [[ "$PROFILE" =~ ^[a-z0-9][a-z0-9_-]{0,63}$ ]]; then
  echo "error: agent name '$AGENT_INPUT' normalizes to '$PROFILE', which is not a valid" >&2
  echo "       profile id. Must match ^[a-z0-9][a-z0-9_-]{0,63}\$ after lowercasing" >&2
  echo "       (it becomes a directory, a Mnemosyne bank, and a systemd unit name)." >&2
  exit 1
fi

# Hermes refuses these outright (_RESERVED_NAMES in hermes_cli/profiles.py):
# they collide with the install dir or a common system binary. 'default' is the
# built-in root profile — provisioning it here would target the ROOT install,
# not a sibling profile, which is exactly the accident this script guards.
for _reserved in hermes default test tmp root sudo; do
  if [[ "$PROFILE" == "$_reserved" ]]; then
    echo "error: agent name '$PROFILE' is reserved by Hermes — pick another." >&2
    exit 1
  fi
done

# Derived shared paths (after --shared-root is known).
: "${SHARED_SKILLS:=${SHARED_ROOT}/skills}"
: "${SHARED_PLUGINS:=${SHARED_ROOT}/hermes/plugins}"
: "${SHARED_SURFACE_DB:=${SHARED_ROOT}/mnemosyne.db}"

ROOT_HOME="/home/${AGENT_UID_NAME}/.hermes"
PROFILE_DIR="${ROOT_HOME}/profiles/${PROFILE}"
HERMES_BIN="${ROOT_HOME}/hermes-agent/venv/bin/hermes"
PYBIN="${ROOT_HOME}/hermes-agent/venv/bin/python"
: "${DESCRIPTION:=Hermes agent profile '${PROFILE}' on $(hostname -s).}"

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
# Hermes CLI scoped to the new profile's home.
phermes() {
  if [[ $DRY_RUN -eq 1 ]]; then printf '  [dry] hermes -p %s %s\n' "$PROFILE" "$*"; return 0; fi
  sudo -n -u "$AGENT_UID_NAME" env HERMES_HOME="$PROFILE_DIR" "$HERMES_BIN" "$@"
}

# Read the soul BEFORE doing anything destructive, so a bad path fails early.
if [[ "$SOUL_FILE" == "-" ]]; then
  SOUL_CONTENT="$(cat)"
else
  [[ -r "$SOUL_FILE" ]] || die "soul file not readable: $SOUL_FILE"
  SOUL_CONTENT="$(cat "$SOUL_FILE")"
fi
[[ -n "${SOUL_CONTENT// /}" ]] || die "soul file is empty: $SOUL_FILE"

say "Provisioning '$PROFILE' under uid '$AGENT_UID_NAME'"
printf '  profile dir : %s\n' "$PROFILE_DIR"
printf '  soul        : %s (%d bytes)\n' "$SOUL_FILE" "${#SOUL_CONTENT}"
printf '  primary     : %s / %s\n' "$PRIMARY_PROVIDER" "$PRIMARY_MODEL"
printf '  shared root : %s\n' "$SHARED_ROOT"

# ---------------------------------------------------------------- phase 0
say "Phase 0 — preflight"
id "$AGENT_UID_NAME" >/dev/null 2>&1 || die "user $AGENT_UID_NAME does not exist"
sudo -n true 2>/dev/null || die "passwordless sudo unavailable"
# The uid's home is typically 0750, so as a different uid we cannot stat inside
# it directly — every existence check must go through sudo.
sudo -n test -x "$HERMES_BIN" || die "hermes binary not found at $HERMES_BIN"
sudo -n test -x "$PYBIN"      || die "venv python not found at $PYBIN"
ok "hermes: $(sudo -n -u "$AGENT_UID_NAME" "$HERMES_BIN" --version 2>/dev/null | head -1 || echo unknown)"

# Refuse to collide with an existing SIBLING profile's identity by accident.
if sudo -n test -d "$PROFILE_DIR"; then
  ok "profile '$PROFILE' already exists — running idempotently against it"
fi

# Both fallback legs traverse the SAME shim and the SAME upstream gateway.
# That is 2 real failure domains, not 3. Prove the local leg now; a dead vLLM
# means the agent silently bills the paid fallback instead of failing loudly.
if curl -fsS --max-time 5 "${VLLM_URL}/models" -o /dev/null 2>/dev/null; then
  ok "vLLM endpoint reachable ($VLLM_URL)"
else
  warn "vLLM NOT reachable — '$PROFILE' would run entirely on paid fallbacks"
fi
if curl -fsS --max-time 5 "${SHIM_URL}/v1/models" -o /dev/null 2>/dev/null; then
  ok "argo-shim reachable ($SHIM_URL)"
else
  warn "argo-shim NOT reachable — fallback legs are dead"
fi

# ---------------------------------------------------------------- phase 1
say "Phase 1 — protect the existing agents (uid-shared filesystem is the real risk)"
if [[ $DRY_RUN -eq 0 ]]; then
  # PITFALL (measured): `hermes backup --quick` IGNORES -o entirely. It writes a
  # timestamped dir under <root>/state-snapshots/ and still exits 0, so a naive
  # `-o` + success check reports a backup that does not exist. Verify the
  # ARTIFACT, never the exit code.
  SNAPDIR="${ROOT_HOME}/state-snapshots"
  BEFORE=$(sudo -n ls -1 "$SNAPDIR" 2>/dev/null | wc -l)
  asagent "$HERMES_BIN" backup --quick >/dev/null 2>&1 || true
  AFTER=$(sudo -n ls -1 "$SNAPDIR" 2>/dev/null | wc -l)
  NEWSNAP=$(sudo -n ls -1t "$SNAPDIR" 2>/dev/null | head -1)
  if [[ "$AFTER" -gt "$BEFORE" ]] && sudo -n test -n "$NEWSNAP"; then
    SZ=$(sudo -n du -sh "${SNAPDIR}/${NEWSNAP}" 2>/dev/null | cut -f1)
    ok "root-profile state snapshot: ${SNAPDIR}/${NEWSNAP} (${SZ})"
  else
    warn "root snapshot NOT created (count ${BEFORE}->${AFTER}) — existing state is unprotected"
  fi
else
  printf '  [dry] hermes backup --quick (root profile)\n'
fi

# ---------------------------------------------------------------- phase 2
say "Phase 2 — create the profile"
if sudo -n test -d "$PROFILE_DIR"; then
  ok "profile '$PROFILE' already exists (idempotent, reusing)"
elif [[ $DRY_RUN -eq 1 ]]; then
  printf '  [dry] hermes profile create %s --no-skills --description ...\n' "$PROFILE"
else
  # --no-skills: opt out of bundled-skill sync; the agent reads the SHARED
  # skills tree instead, so bundled copies would shadow it.
  asagent env HERMES_HOME="$ROOT_HOME" "$HERMES_BIN" profile create "$PROFILE" \
    --no-skills --description "$DESCRIPTION" \
    >/dev/null 2>&1 || die "profile create failed"
  ok "created profile '$PROFILE'"
fi

# ---------------------------------------------------------------- phase 3
say "Phase 3 — model-provider plugins (REQUIRED before the config is usable)"
# MEASURED FAILURE: setting fallback_providers to argo-anthropic / argo-openai
# is NOT sufficient. Those providers are PLUGINS, resolved per-HERMES_HOME from
# <home>/plugins/model-providers/. A profile starts with no plugins dir, so both
# fallback legs die with "Unknown provider 'argo-anthropic'". Symlink the shared
# plugins into the profile, exactly as the root profile does.
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
  # Mnemosyne is a plugin too — link it from the same venv the root profile uses.
  # The python version is GLOBBED, not hardcoded: create-benedict.sh pinned
  # python3.11, which silently breaks the memory subsystem after a venv rebuild
  # on a different interpreter.
  MNEMO_SRC="$(sudo -n bash -c "ls -d ${ROOT_HOME}/hermes-agent/venv/lib/python*/site-packages/mnemosyne_hermes 2>/dev/null | head -1")"
  if [[ -n "$MNEMO_SRC" ]] && sudo -n test -d "$MNEMO_SRC"; then
    sudo -n -u "$AGENT_UID_NAME" ln -sfn "$MNEMO_SRC" "${PROFILE_DIR}/plugins/mnemosyne"
    ok "linked mnemosyne plugin ($(basename "$(dirname "$(dirname "$MNEMO_SRC")")"))"
  else
    warn "mnemosyne package not found under ${ROOT_HOME}/hermes-agent/venv/lib/python*/site-packages"
  fi
fi

# ---------------------------------------------------------------- phase 3b
say "Phase 3b — model chain (local primary, 2 fallbacks)"
# `config set` CANNOT grow a list — a JSON-array string is stored literally
# with a false success tick (measured). Structural list changes must go through
# `config edit` with $EDITOR pointed at a wrapper SCRIPT (single argv0; a
# heredoc or multi-word EDITOR string does not work).
if [[ $DRY_RUN -eq 0 ]]; then
  MUT="/tmp/${PROFILE}-cfg-mutate.$$.py"
  WRAP="/tmp/${PROFILE}-cfg-editor.$$.sh"

  # Values are passed through the ENVIRONMENT, not interpolated into the python
  # source, so a name/url containing quotes cannot break out of the literal.
  sudo -n -u "$AGENT_UID_NAME" tee "$MUT" >/dev/null <<'PYEOF'
import os, sys
from ruamel.yaml import YAML
y = YAML(); y.preserve_quotes = True
p = sys.argv[1]
with open(p) as f:
    cfg = y.load(f) or {}
cfg["provider"] = os.environ["P_PROVIDER"]
cfg["model"] = os.environ["P_MODEL"]
cfg["custom_providers"] = [{
    "name": os.environ["P_PROVIDER"], "base_url": os.environ["P_VLLM"],
    "api_key": "local-noauth", "api_mode": "chat_completions",
    "models": [os.environ["P_MODEL"]],
}]
# Config-hygiene preference: one clean section per endpoint, each listing only
# its own models with an explicit api_mode — never a mixed entry.
shim = os.environ["P_SHIM"]
cfg["fallback_providers"] = [
    {"provider": "argo-anthropic", "model": "Claude Sonnet 5",
     "base_url": shim, "api_mode": "anthropic", "api_key": "shim-noauth"},
    {"provider": "argo-openai", "model": "GPT-5.6 Terra",
     "base_url": shim + "/v1", "api_mode": "chat_completions", "api_key": "shim-noauth"},
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
    P_PROVIDER="$PRIMARY_PROVIDER" P_MODEL="$PRIMARY_MODEL" \
    P_VLLM="$VLLM_URL" P_SHIM="$SHIM_URL" \
    "$HERMES_BIN" config edit >/dev/null 2>&1 || die "config edit failed"
  sudo -n rm -f "$MUT" "$WRAP"

  # Read back and assert the list COUNT — a bad ruamel round-trip can silently
  # empty a list while leaving a file that still parses and passes checks.
  NFB=$(sudo -n -u "$AGENT_UID_NAME" "$PYBIN" -c \
    "import yaml;print(len((yaml.safe_load(open('${PROFILE_DIR}/config.yaml')) or {}).get('fallback_providers') or []))")
  NCP=$(sudo -n -u "$AGENT_UID_NAME" "$PYBIN" -c \
    "import yaml;print(len((yaml.safe_load(open('${PROFILE_DIR}/config.yaml')) or {}).get('custom_providers') or []))")
  [[ "$NCP" == "1" ]] || die "custom_providers count = $NCP, expected 1"
  [[ "$NFB" == "2" ]] || die "fallback_providers count = $NFB, expected 2"
  ok "primary=${PRIMARY_PROVIDER}/${PRIMARY_MODEL}; fallbacks=$NFB (Sonnet 5, GPT-5.6 Terra)"
fi

# ---------------------------------------------------------------- phase 4
say "Phase 4 — memory subsystem (Mnemosyne)"
# THE LOAD-BEARING SETTING. profile_isolation defaults to FALSE. With it off,
# the provider falls through to bank "default" — this agent would write into
# the ROOT profile's Mnemosyne bank. Verified in mnemosyne_hermes/__init__.py:
# the `if self._profile_isolation_enabled:` branch is the only path that calls
# _resolve_profile_bank(); otherwise the legacy shared DB is used.
phermes config set memory.provider mnemosyne               >/dev/null 2>&1 || warn "memory.provider"
phermes config set memory.mnemosyne.profile_isolation true >/dev/null 2>&1 || warn "profile_isolation"
phermes config set memory.mnemosyne.default_scope global   >/dev/null 2>&1 || warn "default_scope"

# Shared cross-agent surface: read-only participation in the sibling knowledge
# pool. Private bank stays per-profile.
#
# PREFLIGHT: shared_surface_path is only half the story. There is NO
# `shared_surface_write` config key — writes to the surface DB are gated purely
# by FILESYSTEM permissions (the DB is 0660 <owner>:<group>). So participation
# requires the agent's uid to be in that group. On this host it passes only
# because the default uid already happens to be a member; an agent on a NEW uid
# would get a silently degraded profile: config present, surface unreadable.
if sudo -n test -e "$SHARED_SURFACE_DB"; then
  SURF_GRP=$(sudo -n stat -c '%G' "$SHARED_SURFACE_DB")
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

phermes config set memory.mnemosyne.shared_surface_path "$SHARED_SURFACE_DB" >/dev/null 2>&1 || warn "surface path"
phermes config set memory.mnemosyne.shared_surface_read true >/dev/null 2>&1 || warn "surface read"
ok "mnemosyne configured (profile_isolation ON — verified in phase 7)"

# Consolidation must run against the local endpoint, not the default CPU GGUF
# (measured elsewhere: slow AND leaks raw <think> into episodic rows).
#
# IDEMPOTENCY (measured 2026-08-26): a bare `tee -a` DUPLICATES every key on a
# re-run. Observed on a real second pass: .env went 27 -> 45 lines with
# MNEMOSYNE_LLM_ENABLED present twice. python-dotenv takes the LAST value, so
# it is not immediately fatal, but it makes the file unreadable and any later
# hand-edit of the first occurrence silently does nothing. Only append keys
# that are not already present, and never re-add the block header.
if [[ $DRY_RUN -eq 0 ]]; then
  ENVF="${PROFILE_DIR}/.env"
  sudo -n test -f "$ENVF" || sudo -n -u "$AGENT_UID_NAME" touch "$ENVF"

  env_has() { sudo -n grep -qE "^[[:space:]]*${1}=" "$ENVF" 2>/dev/null; }
  ADDED=0; SKIPPED=0
  add_env() { # key value
    if env_has "$1"; then SKIPPED=$((SKIPPED+1)); return 0; fi
    if [[ $ADDED -eq 0 ]]; then
      printf '\n# ---- added by create-profile.sh for %s on %s ----\n' \
        "$PROFILE" "$(date -Iseconds)" | sudo -n -u "$AGENT_UID_NAME" tee -a "$ENVF" >/dev/null
    fi
    printf '%s=%s\n' "$1" "$2" | sudo -n -u "$AGENT_UID_NAME" tee -a "$ENVF" >/dev/null
    ADDED=$((ADDED+1))
  }

  # Argo shim provider keys. NOT secrets: the local shim performs no
  # authentication (verified — a deliberate garbage bearer token still returns
  # HTTP 200). Hermes only requires the vars to be non-empty, so a placeholder
  # is correct here and no real credential is copied into this profile.
  add_env ARGO_ANTHROPIC_KEY shim-noauth
  add_env ARGO_OPENAI_KEY    shim-noauth
  # Mnemosyne consolidation -> local endpoint (avoids CPU GGUF <think> leak)
  add_env MNEMOSYNE_LLM_ENABLED       true
  add_env MNEMOSYNE_HOST_LLM_ENABLED  true
  add_env MNEMOSYNE_LLM_BASE_URL      "$VLLM_URL"
  add_env MNEMOSYNE_LLM_MODEL         "$PRIMARY_MODEL"
  add_env MNEMOSYNE_LLM_TIMEOUT       120
  add_env MNEMOSYNE_LLM_MAX_TOKENS    2048
  add_env MNEMOSYNE_AUTO_SLEEP_ENABLED true
  add_env MNEMOSYNE_CROSS_SESSION     true

  sudo -n chmod 0600 "$ENVF"
  ok "env: ${ADDED} key(s) added, ${SKIPPED} already present (idempotent); .env is 0600"

  # Assert no key was duplicated — the failure mode this block exists to avoid.
  DUPES=$(sudo -n grep -oE '^[[:space:]]*[A-Z_][A-Z0-9_]*=' "$ENVF" 2>/dev/null \
          | tr -d ' ' | sort | uniq -d | tr '\n' ' ')
  if [[ -n "${DUPES// /}" ]]; then
    warn "DUPLICATE .env keys present: $DUPES"
  else
    ok "no duplicate keys in .env"
  fi
fi

# ---------------------------------------------------------------- phase 5
say "Phase 5 — shared knowledge (skills)"
phermes config set skills.external_dirs "$SHARED_SKILLS" >/dev/null 2>&1 || warn "external_dirs"
ok "shared skills wired: $SHARED_SKILLS"
if [[ -n "$KANBAN_HOME" ]]; then
  phermes config set kanban.home "$KANBAN_HOME" >/dev/null 2>&1 || warn "kanban.home"
  warn "shared kanban board opted in: $KANBAN_HOME — every participant must know it exists"
else
  ok "kanban: default per-profile board only (no shared board, by design)"
fi

# ---------------------------------------------------------------- phase 6
say "Phase 6 — SOUL.md"
if [[ $DRY_RUN -eq 0 ]]; then
  printf '%s\n' "$SOUL_CONTENT" | sudo -n -u "$AGENT_UID_NAME" tee "${PROFILE_DIR}/SOUL.md" >/dev/null
  ok "SOUL.md written ($(sudo -n stat -c%s "${PROFILE_DIR}/SOUL.md") bytes) from $SOUL_FILE"
else
  printf '  [dry] write SOUL.md (%d bytes) from %s\n' "${#SOUL_CONTENT}" "$SOUL_FILE"
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
  sudo -n -u "$AGENT_UID_NAME" env HERMES_HOME="$PROFILE_DIR" ROOT_ENV="${ROOT_HOME}/.env" \
    "$PYBIN" - <<'PYCHK'
import os
from dotenv import dotenv_values
import hermes_constants as h
mine = dotenv_values(h.get_env_path())
root = dotenv_values(os.environ["ROOT_ENV"])
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
print(f"  profile keys  : {len(mine)}")
print(f"  shared non-secret settings/placeholders: {benign}")
print(f"  LEAKED SECRETS: {leaked if leaked else 'none'}")
# Positive control: this check must be able to fail. Prove the detector fires
# on a real credential that exists only in the root profile.
canary = [k for k, v in root.items() if is_secret(k, v) and k not in mine]
print(f"  detector positive control: {len(canary)} root-only secret(s) correctly NOT in profile"
      f" (e.g. {canary[0] if canary else 'n/a'})")
raise SystemExit(1 if leaked else 0)
PYCHK
  [[ $? -eq 0 ]] && ok "no credential leak from the root profile's .env" \
                 || { warn "CREDENTIAL LEAK"; FAILED=$((FAILED+1)); }

  # Mnemosyne must resolve a bank named after THIS profile, not 'default'.
  # The plugin SANITIZES bank names, so compare against its own sanitized
  # value rather than the raw argument (create-benedict.sh compared the raw
  # name, which would false-fail on any name needing sanitization).
  say "  memory bank isolation"
  sudo -n -u "$AGENT_UID_NAME" env HERMES_HOME="$PROFILE_DIR" \
    P_PROFILE="$PROFILE" P_DIR="$PROFILE_DIR" "$PYBIN" - <<'PYBANK'
import os
from mnemosyne_hermes import MnemosyneMemoryProvider as P
p = P()
p._hermes_home = os.environ["P_DIR"]
p._agent_identity = os.environ["P_PROFILE"]
bank = p._resolve_profile_bank()
expected = P._sanitize_bank_name(os.environ["P_PROFILE"])
print(f"  resolved bank : {bank}  (expected {expected})")
if bank == "default":
    print("  BANK COLLISION: would write into the root profile's memory")
    raise SystemExit(1)
raise SystemExit(0 if bank == expected else 1)
PYBANK
  [[ $? -eq 0 ]] && ok "mnemosyne bank isolated to '$PROFILE' (not the root 'default')" \
                 || { warn "BANK COLLISION: would write into the root profile's memory"; FAILED=$((FAILED+1)); }

  # Shared surface DB must be FUNCTIONALLY reachable, not merely configured.
  # A config value proves nothing: access is gated by filesystem perms + group
  # membership. Open it as the agent uid and read a real row count.
  say "  shared surface DB reachable as $AGENT_UID_NAME"
  sudo -n -u "$AGENT_UID_NAME" "$PYBIN" - "$SHARED_SURFACE_DB" <<'PYSURF'
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

  if [[ $SKIP_LIVE -eq 0 ]]; then
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
    probe_leg "local (primary)"  "$PRIMARY_PROVIDER" "$PRIMARY_MODEL"  "LOCALOK"
    probe_leg "Claude Sonnet 5"  "argo-anthropic"    "Claude Sonnet 5" "SONNETOK"
    probe_leg "GPT-5.6 Terra"    "argo-openai"       "GPT-5.6 Terra"   "TERRAOK"

    # Memory must write to THIS agent's own bank, proven by a real row on disk,
    # and must be ABSENT from the root bank (negative control).
    say "  memory write lands in ${PROFILE}'s bank"
    BANKDB="${PROFILE_DIR}/mnemosyne/data/banks/${PROFILE}/mnemosyne.db"
    TOKEN="$(echo "$PROFILE" | tr '[:lower:]' '[:upper:]')_VERIFY_$(date +%s)"
    sudo -n -u "$AGENT_UID_NAME" env HERMES_HOME="$PROFILE_DIR" timeout 240 \
      "$HERMES_BIN" -z "Use the mnemosyne_remember tool with content='${TOKEN}' scope='global'. Reply only DONE." >/dev/null 2>&1 || true
    HIT=$(sudo -n sqlite3 "$BANKDB" "select count(*) from working_memory where content like '%${TOKEN}%';" 2>/dev/null || echo 0)
    ROOT_HIT=$(sudo -n sqlite3 "${ROOT_HOME}/mnemosyne/data/mnemosyne.db" "select count(*) from working_memory where content like '%${TOKEN}%';" 2>/dev/null || echo 0)
    if [[ "$HIT" -ge 1 && "$ROOT_HIT" -eq 0 ]]; then
      ok "memory row in ${PROFILE}'s bank ($HIT), absent from root's (negative control passed)"
    else
      warn "memory isolation FAILED: ${PROFILE}=$HIT root=$ROOT_HIT"; FAILED=$((FAILED+1))
    fi
  else
    warn "live model + memory-write checks SKIPPED (--skip-live-checks): the chain is CONFIGURED but UNPROVEN"
  fi

  say "  resolved model chain"
  phermes config get model; phermes config get provider
  phermes config get fallback_providers 2>&1 | head -12
fi

say "RESULT"
if [[ $DRY_RUN -eq 1 ]]; then
  echo "  dry-run complete, nothing written."
elif [[ $FAILED -eq 0 ]]; then
  echo "  '$PROFILE' provisioned. $FAILED checks failed."
  echo
  echo "  STILL REQUIRED BEFORE THIS AGENT CAN TALK:"
  echo "    - Discord bot token  -> ${PROFILE_DIR}/.env  (DISCORD_BOT_TOKEN=)"
  echo "    - Gmail creds        -> ${PROFILE_DIR}/.env  (EMAIL_PASSWORD=)  [if used]"
  echo "    - gateway unit       -> not installed until a token exists"
  echo "                            (unit name: hermes-gateway-${PROFILE}.service)"
  echo
  echo "  Test first with:  sudo -u $AGENT_UID_NAME env HERMES_HOME=$PROFILE_DIR $HERMES_BIN"
else
  die "$FAILED verification check(s) failed — '$PROFILE' is NOT ready"
fi
