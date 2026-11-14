#!/bin/sh
# Check the boundary from outside sbx: ./tests/verify.sh [repo]
# Needs network for the first test; skips it if offline.
set -u
SBX="$(cd "$(dirname "$0")/.." && pwd)/sbx"
REPO="${1:-$(mktemp -d)}"
[ -d "$REPO" ] || { echo "no such dir: $REPO" >&2; exit 1; }
mkdir -p "$REPO" && cd "$REPO" || exit 1
[ -d .git ] || git init -q
pass=0 fail=0
check() { # name, expect(pass|fail), command...
  name="$1" expect="$2"; shift 2
  if out=$("$@" 2>&1) && [ -n "$out" ] && ! echo "$out" | grep -qiE "operation not permitted|not logged in|could not|denied|EPERM|error"; then got=pass; else got=fail; fi
  if [ "$got" = "$expect" ]; then pass=$((pass+1)); printf '  ok   %-34s (%s)\n' "$name" "$got"
  else fail=$((fail+1)); printf '  FAIL %-34s expected %s, got %s: %s\n' "$name" "$expect" "$got" "$(echo "$out" | head -1)"; fi
}
echo "repo: $REPO"
check "write in project"        pass "$SBX" sh -c 'echo x > .sbx-probe && echo wrote'
check "read ~/.ssh"             fail "$SBX" sh -c 'ls ~/.ssh'
check "write outside project"   fail "$SBX" sh -c 'echo x > ~/.sbx-escape && echo wrote'
check "git commit"              pass "$SBX" sh -c 'echo y >> .sbx-probe && git add -A && git -c user.email=t@t -c user.name=t commit -qm probe && echo committed'
check "git hooks write"         fail "$SBX" sh -c 'echo x > .git/hooks/pre-commit && echo wrote'
check "ssh-agent"               fail "$SBX" ssh-add -l
check "docker socket"           fail "$SBX" sh -c 'curl -s --max-time 5 --unix-socket ~/.colima/default/docker.sock http://x/_ping'
check "dns resolution"          pass "$SBX" python3 -c 'import socket;print(socket.gethostbyname("example.com"))'
check "https egress"            pass "$SBX" sh -c 'curl -s -o /dev/null -w "%{http_code}" https://example.com'
check "no-network blocks egress" fail "$SBX" --no-network sh -c 'curl -s -m 5 -o /dev/null -w "%{http_code}" https://example.com'
check "dev server binds"        pass "$SBX" sh -c 'python3 -c "import socket;s=socket.socket();s.bind((\"127.0.0.1\",0));s.listen();print(s.getsockname()[1])"'
printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
