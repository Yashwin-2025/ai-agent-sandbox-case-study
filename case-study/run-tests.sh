#!/usr/bin/env bash
# OpenShell sandbox security checks. Run INSIDE the sandbox:  bash run-tests.sh
# Each check prints PASS/FAIL, the security property, and the layer that enforces it.
#   L1 = Linux permissions   L2 = container isolation   L3 = OpenShell policy

PASS=0; FAIL=0

# check <id> <layer> <property> <expect: ok|fail> <command...>
check() {
  local id=$1 layer=$2 prop=$3 expect=$4; shift 4
  local out; out=$("$@" 2>&1); local rc=$?
  local got=ok; [ $rc -ne 0 ] && got=fail
  if [ "$got" = "$expect" ]; then r=PASS; PASS=$((PASS+1)); else r=FAIL; FAIL=$((FAIL+1)); fi
  printf '%-4s %-3s %-5s %-44s | %s\n' "$r" "$id" "$layer" "$prop" "$(echo "$out" | head -1 | cut -c1-70)"
}

# net <url>: exit 0 if the HTTPS request gets any HTTP response, 1 if the connection is refused
net() {
  node -e "
    fetch(process.argv[1], {method:'HEAD', signal: AbortSignal.timeout(8000)})
      .then(r => { console.log('HTTP', r.status); process.exit(0) })
      .catch(e => { console.log('BLOCKED', (e.cause && e.cause.code) || e.name); process.exit(1) })" "$1"
}

# tcp <ip> <port>: raw TCP connect, bypassing DNS
tcp() {
  node -e "
    const s = require('net').connect({host: process.argv[1], port: +process.argv[2], timeout: 5000});
    s.on('connect', () => { console.log('CONNECTED'); process.exit(0) });
    s.on('error', e => { console.log('BLOCKED', e.code); process.exit(1) });
    s.on('timeout', () => { console.log('BLOCKED timeout'); process.exit(1) })" "$1" "$2"
}

echo "== Identity and privilege"
check 1   L1    "Runs as non-root (uid 1000)"               ok   sh -c 'id; [ "$(id -u)" = 1000 ]'
check 4a  L1    "sudo not available"                        fail sudo -n id
check 4b  L1    "su to root fails"                          fail sh -c 'su -c id root </dev/null'
check 4c  L2    "No effective capabilities"                 ok   sh -c 'grep CapEff /proc/self/status; grep -q "CapEff:.0000000000000000" /proc/self/status'
check 4d  L2    "no_new_privs set (no setuid escalation)"   ok   sh -c 'grep NoNewPrivs /proc/self/status; grep -q "NoNewPrivs:.1" /proc/self/status'

echo "== Filesystem"
check 2   L1+L3 "Workspace is writable"                     ok   sh -c 'echo hi > /workspace/.cs-test && cat /workspace/.cs-test'
check 3   L1+L3 "Cannot write /etc"                         fail touch /etc/cs-test
check 3b  L1+L3 "Cannot write /usr (image files)"           fail touch /usr/local/bin/cs-test
check 5a  L1+L3 "Cannot read /root"                         fail ls /root
check 5b  L3    "Own home hidden despite ownership"         fail ls /home/node
check 5c  L3    "Tmp writable, but only allowlisted dirs"   ok   sh -c 'touch /tmp/cs-test && echo ok'

echo "== Container isolation"
check 6   L2    "No Docker socket"                          fail test -S /var/run/docker.sock
check 7   L2    "Own PID namespace (few processes)"         ok   sh -c 'n=$(ls -d /proc/[0-9]* | wc -l); echo "$n processes visible"; [ "$n" -lt 50 ]'

echo "== Network (OpenShell egress policy)"
check 8   L3    "Default-deny: example.com blocked"         fail net https://example.com
check 8b  L3    "Default-deny: api.anthropic.com blocked"   fail net https://api.anthropic.com
check 8c  L3    "Raw IP bypass blocked (1.1.1.1:443)"       fail tcp 1.1.1.1 443
check 9   L3    "Allowlisted binary: claude -> openrouter"  ok   bash -c 'ANTHROPIC_AUTH_TOKEN="$OPENROUTER_API_KEY" timeout 90 claude -p "reply ok" --max-turns 1 </dev/null >/tmp/c9 2>&1; rc=$?; grep -q "API Error\|Not logged in\|ECONNREFUSED" /tmp/c9 && rc=1; echo "claude exit=$rc"; exit $rc'
check 9b  L3    "Binary identity: node -> openrouter denied" fail net https://openrouter.ai/api/v1/models
check 10  L3    "Policy DNS returns synthetic 198.18.x"     ok   sh -c "node -e \"require('dns').lookup('example.com',(e,a)=>{console.log(e?e.code:a);process.exit(a&&a.startsWith('198.18.')?0:1)})\""
check 11  L3    "Binary identity: git -> openrouter denied" fail git ls-remote https://openrouter.ai/x.git

echo "== Credentials"
check 12a L3    "Provider key is a placeholder"             ok   bash -c 'echo "${OPENROUTER_API_KEY:0:10}..."; case "$OPENROUTER_API_KEY" in openshell:*) exit 0;; *) exit 1;; esac'
check 12b L3    "No real secret-looking env values"         ok   sh -c 'hits=$(env | grep -iE "(KEY|TOKEN|SECRET|PASSWORD)=" | grep -v "=openshell:" | grep -vE "=$"); echo "${hits:-none}" | cut -d= -f1; [ -z "$hits" ]'

rm -f /workspace/.cs-test /tmp/cs-test
echo
echo "RESULT: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
