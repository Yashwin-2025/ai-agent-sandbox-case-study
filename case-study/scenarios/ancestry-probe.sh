#!/usr/bin/env bash
# Does a process inherit network permission from its parent? Runs the same probes twice:
#   1. from a plain shell        (parent chain: bash)
#   2. from a Claude Code hook   (parent chain: claude.exe -> bash)
# Run INSIDE the sandbox:  bash ancestry-probe.sh
# The hook variant uses a SessionStart hook, so no model call is needed for the probes.

probes() {
  local who=$1
  # P1: node, no credential, public endpoint
  node -e "fetch('https://openrouter.ai/api/v1/models',{method:'HEAD',signal:AbortSignal.timeout(8000)})
    .then(r=>console.log('$who P1 node -> openrouter (no auth)       : HTTP',r.status))
    .catch(e=>console.log('$who P1 node -> openrouter (no auth)       : BLOCKED',e.cause&&e.cause.code||e.name))"
  # P2: node sends the placeholder; 200 means the proxy injected the REAL key for this process
  node -e "fetch('https://openrouter.ai/api/v1/key',{headers:{authorization:'Bearer '+process.env.OPENROUTER_API_KEY},signal:AbortSignal.timeout(8000)})
    .then(r=>console.log('$who P2 node -> openrouter (placeholder key): HTTP',r.status, r.status===200?'(real key injected)':''))
    .catch(e=>console.log('$who P2 node -> openrouter (placeholder key): BLOCKED',e.cause&&e.cause.code||e.name))"
  # P3: git, a binary that is never in the allowlist
  if git ls-remote https://openrouter.ai/x.git >/dev/null 2>&1; then r="reached"; else
     git ls-remote https://openrouter.ai/x.git 2>&1 | grep -q 'Failed to connect' && r="BLOCKED" || r="reached (HTTP error from server)"; fi
  echo "$who P3 git  -> openrouter                   : $r"
}

if [ "$1" = "--probes" ]; then probes "$2"; exit; fi

export ANTHROPIC_AUTH_TOKEN="$OPENROUTER_API_KEY"
SELF=$(readlink -f "$0")

echo "== From a plain shell (parent: bash)"
probes "[shell ]"

echo "== From a Claude Code SessionStart hook (parent: claude.exe)"
mkdir -p /workspace/probe/.claude
cat > /workspace/probe/.claude/settings.json <<EOF
{ "hooks": { "SessionStart": [ { "hooks": [
  { "type": "command", "command": "bash $SELF --probes '[claude]' > /workspace/probe/hook.out 2>&1" } ] } ] } }
EOF
(cd /workspace/probe && timeout 120 claude -p "reply ok" --max-turns 1 --dangerously-skip-permissions < /dev/null > /dev/null 2>&1)
cat /workspace/probe/hook.out 2>/dev/null || echo "hook did not run"
