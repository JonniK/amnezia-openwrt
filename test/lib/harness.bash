# Common bats harness: stubs on PATH, scratch dirs, log file.
HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export STUB_LOG="${BATS_TEST_TMPDIR:-/tmp}/stub.log"
: > "$STUB_LOG"
export PATH="$HARNESS_DIR/stubs:$PATH"
export AMNEZIA_DRYRUN=1

# Skip helper for Tier-2 (real-kernel) tests.
_require_linux_nft() { command -v nft >/dev/null 2>&1 && [ "$(uname -s)" = Linux ]; }
