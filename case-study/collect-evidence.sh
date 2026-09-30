#!/usr/bin/env bash
# Run on the Mac (host). Saves sandbox policy, network audit log, and container
# isolation settings for a sandbox into case-study/evidence/.
#   Usage: case-study/collect-evidence.sh [sandbox-name] [since]    (defaults: agent-sandbox 15m)
set -euo pipefail

NAME=${1:-agent-sandbox}
SINCE=${2:-15m}
DIR=${EVIDENCE_DIR:-"$(cd "$(dirname "$0")" && pwd)/evidence"}
STAMP=$(date +%Y%m%d-%H%M%S)
mkdir -p "$DIR"

echo "== Effective policy"
openshell policy get "$NAME" --full -o json > "$DIR/$STAMP-$NAME-policy.json"

echo "== Network audit log (ALLOWED/DENIED)"
openshell logs "$NAME" --source sandbox --since "$SINCE" -n 2000 \
  | grep -E 'ALLOWED|DENIED' > "$DIR/$STAMP-$NAME-network.log" || true
echo "   allowed: $(grep -c ALLOWED "$DIR/$STAMP-$NAME-network.log" || true)"
echo "   denied:  $(grep -c DENIED  "$DIR/$STAMP-$NAME-network.log" || true)"

echo "== Container isolation settings"
{
  for c in $(docker ps -q --filter "label=openshell.ai/sandbox-name=$NAME"); do
    docker inspect "$c" --format \
      'role={{index .Config.Labels "openshell.ai/isolation-role"}} network={{.HostConfig.NetworkMode}} user={{.Config.User}} privileged={{.HostConfig.Privileged}} readonly_rootfs={{.HostConfig.ReadonlyRootfs}} cap_drop={{.HostConfig.CapDrop}} cap_add={{.HostConfig.CapAdd}} security_opt={{.HostConfig.SecurityOpt}} docker_sock_mounted={{range .Mounts}}{{if eq .Source "/var/run/docker.sock"}}YES{{end}}{{end}}'
  done
} > "$DIR/$STAMP-$NAME-containers.txt"
cat "$DIR/$STAMP-$NAME-containers.txt"

echo
echo "Saved to $DIR/$STAMP-$NAME-*"
