#!/usr/bin/env bats
load '../lib/harness.bash'
SCRIPT="$HARNESS_DIR/../openwrt/zapret-probe.sh"

@test "pinned-IP invocation passes --resolve and --max-redirs 0 to curl" {
  run sh "$SCRIPT" example.com 93.184.216.34
  grep -q -- '--resolve example.com:443:93.184.216.34' "$STUB_LOG"
  grep -q -- '--resolve example.com:80:93.184.216.34' "$STUB_LOG"
  grep -q -- '--max-redirs 0' "$STUB_LOG"
}
@test "unpinned invocation is byte-equivalent: -sL preserved, no --resolve/--max-redirs" {
  run sh "$SCRIPT" example.com
  run grep -q -- '--resolve' "$STUB_LOG"; [ "$status" -ne 0 ]
  run grep -q -- '--max-redirs' "$STUB_LOG"; [ "$status" -ne 0 ]
  grep -q -- '-sL' "$STUB_LOG"        # silent + follow-redirects retained
  grep -q -- '-D ' "$STUB_LOG"        # header dump still requested
  grep -q -- "%{http_code}" "$STUB_LOG"
}
@test "pinned-IP arg is validated (rejects non-IP)" {
  run sh "$SCRIPT" example.com not-an-ip
  echo "$output" | grep -q '"verdict": *"error"'
  [ "$status" -ne 0 ]
}
