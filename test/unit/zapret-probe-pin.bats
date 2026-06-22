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
@test "SSRF guard: loopback 127.0.0.1 rejected with error verdict" {
  run sh "$SCRIPT" foo.example 127.0.0.1
  echo "$output" | grep -q '"verdict":"error"'
  echo "$output" | grep -q 'pinned ip not public'
  [ "$status" -ne 0 ]
}
@test "SSRF guard: private 192.168.1.1 rejected with error verdict" {
  run sh "$SCRIPT" foo.example 192.168.1.1
  echo "$output" | grep -q '"verdict":"error"'
  echo "$output" | grep -q 'pinned ip not public'
  [ "$status" -ne 0 ]
}
@test "SSRF guard: link-local 169.254.1.1 rejected" {
  run sh "$SCRIPT" foo.example 169.254.1.1
  echo "$output" | grep -q '"verdict":"error"'
  [ "$status" -ne 0 ]
}
@test "SSRF guard: 10.x private rejected" {
  run sh "$SCRIPT" foo.example 10.0.0.1
  echo "$output" | grep -q '"verdict":"error"'
  [ "$status" -ne 0 ]
}
@test "SSRF guard: multicast 224.0.0.1 rejected" {
  run sh "$SCRIPT" foo.example 224.0.0.1
  echo "$output" | grep -q '"verdict":"error"'
  [ "$status" -ne 0 ]
}
@test "SSRF guard: public IP 93.184.216.34 is NOT rejected" {
  run sh "$SCRIPT" example.com 93.184.216.34
  # Must not be an error verdict from the guard (it may fail curl but not with our guard reason)
  run grep -q 'pinned ip not public' "$STUB_LOG"; [ "$status" -ne 0 ]
}
