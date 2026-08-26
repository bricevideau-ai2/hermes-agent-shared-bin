#!/usr/bin/env bash
# create-benedict.sh — DEPRECATED SHIM (2026-08-26).
#
# The provisioning logic is now generalized in create-profile.sh, which takes
# the agent name and a soul file as arguments. This wrapper is kept so existing
# references and muscle memory keep working; it simply forwards.
#
# Benedict's soul now lives at ./souls/benedict.md rather than embedded in a
# heredoc, so it can be edited without touching provisioning code. It sits
# INSIDE the bin repo (not a sibling dir) so a fresh clone is self-contained.
#
# Fixes that came with the generalization (all measured, see git log):
#   - .env keys were DUPLICATED on every re-run (27 -> 45 lines observed);
#     create-profile.sh appends only missing keys and asserts no duplicates.
#   - python3.11 was hardcoded in the mnemosyne plugin path; now globbed.
#   - the mnemosyne bank assertion compared the RAW profile name, but the
#     plugin sanitizes bank names; now compares the sanitized value.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOUL="${HERE}/souls/benedict.md"

echo "[deprecated] create-benedict.sh now forwards to create-profile.sh" >&2
echo "[deprecated]   equivalent: create-profile.sh benedict ${SOUL} \"\$@\"" >&2

[[ -r "$SOUL" ]] || { echo "soul file missing: $SOUL" >&2; exit 1; }

exec "${HERE}/create-profile.sh" benedict "$SOUL" \
  --description "Local-first mechanical worker on shared vLLM. Cheap, verifiable, scope-bounded tasks: greps, builds, log triage, file transforms, test runs. Escalates rather than guesses." \
  "$@"
