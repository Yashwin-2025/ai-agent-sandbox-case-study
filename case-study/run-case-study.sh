#!/usr/bin/env bash
# Reproduce the whole case study with one command. Run on the host from the repo root:
#
#   case-study/run-case-study.sh                        # preflight, build, tests, ancestry probe
#   case-study/run-case-study.sh --scenarios MODEL      # also run the agent attack scenarios
#                                                       # (MODEL e.g. anthropic/claude-haiku-4.5 — PAID)
#
# Each stage runs in a fresh, throwaway sandbox. Results land in case-study/evidence/run-<timestamp>/.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CS="$ROOT/case-study"
IMAGE=claude-agent:local
PROVIDER=openrouter
SCENARIO_MODEL=""
[ "${1:-}" = "--scenarios" ] && SCENARIO_MODEL=${2:?"usage: --scenarios <openrouter-model-id>"}

RUN="$CS/evidence/run-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN"
say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------- preflight
say "Preflight"
openshell status >/dev/null || { echo "OpenShell gateway not reachable (brew services start openshell)"; exit 1; }
docker info >/dev/null 2>&1 || { echo "Docker is not running"; exit 1; }
docker run --rm --network host alpine nc -z -w3 127.0.0.1 17670 >/dev/null 2>&1 \
  || { echo "Host-network containers can't reach the gateway: enable Docker Desktop > Settings > Resources > Network > Enable host networking"; exit 1; }
openshell profile describe "$PROVIDER" | sed -n '/Binaries:/,$p' | tee "$RUN/provider-binaries.txt"
echo "ok"

# ---------------------------------------------------------------- build
say "Build $IMAGE"
docker build -q -f "$ROOT/Dockerfile.claude" -t "$IMAGE" "$ROOT"

# ---------------------------------------------------------------- helper
# in_sandbox <name> <script> [extra files to place next to it...]
# Copies the script (and extra files/dirs) into a fresh sandbox, runs it, captures output
# and evidence, then deletes the sandbox.
in_sandbox() {
  local name=$1 script=$2; shift 2
  local payload; payload=$(COPYFILE_DISABLE=1 tar czf - -C "$(dirname "$script")" "$(basename "$script")" "$@" | base64)
  openshell sandbox delete "$name" >/dev/null 2>&1 || true
  openshell sandbox create --name "$name" --from "$IMAGE" --provider "$PROVIDER" --no-tty -- \
    bash -c "echo '$payload' | base64 -d | tar xzf - -C /workspace 2>/dev/null
             ${STAGE_ENV:-} bash /workspace/$(basename "$script")
             echo __STAGE_DONE__; sleep 90" > "$RUN/$name-output.txt" 2>&1 &
  local pid=$!
  for _ in $(seq 1 450); do grep -q __STAGE_DONE__ "$RUN/$name-output.txt" 2>/dev/null && break; sleep 2; done
  EVIDENCE_DIR="$RUN" "$CS/collect-evidence.sh" "$name" 30m >/dev/null
  openshell sandbox delete "$name" >/dev/null 2>&1 || true
  kill "$pid" 2>/dev/null || true
}

# ---------------------------------------------------------------- stages
say "Stage 1: sandbox property tests"
in_sandbox cs-tests "$CS/run-tests.sh"
grep -E '^(PASS|FAIL)|^RESULT' "$RUN/cs-tests-output.txt"

say "Stage 2: process-ancestry probe"
in_sandbox cs-ancestry "$CS/scenarios/ancestry-probe.sh"
grep -E '^\[(shell |claude)\]' "$RUN/cs-ancestry-output.txt"

if [ -n "$SCENARIO_MODEL" ]; then
  say "Stage 3: agent attack scenarios with $SCENARIO_MODEL (this spends OpenRouter credits)"
  STAGE_ENV="MODEL=$SCENARIO_MODEL MAX_TURNS=8" in_sandbox cs-agent "$CS/scenarios/run-scenarios.sh" injected-repo
  grep -E '^(=====|  (TOOL|SAYS|END|COST))' "$RUN/cs-agent-output.txt" | cut -c1-200
fi

say "Done: evidence in ${RUN#$ROOT/}"
