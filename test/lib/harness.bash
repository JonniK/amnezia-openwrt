# Common bats harness: stubs on PATH, scratch dirs, log file.
HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export STUB_LOG="${BATS_TEST_TMPDIR:-/tmp}/stub.log"
: > "$STUB_LOG"
export PATH="$HARNESS_DIR/stubs:$PATH"
export AMNEZIA_DRYRUN=1

# Skip helper for Tier-2 (real-kernel) tests.
# Checks the REAL system binaries (not the test/stubs/ shims on PATH) so a
# stub on PATH cannot mask a missing system nft or ip installation.
_require_linux_nft() {
  [ "$(uname -s)" = Linux ] || return 1
  { [ -x /usr/sbin/nft ] || [ -x /sbin/nft ]; } || return 1
  { [ -x /sbin/ip ]      || [ -x /usr/sbin/ip ]; }
}
