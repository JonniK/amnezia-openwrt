#!/bin/sh
# dev/build-covert-creator.sh
#
# Cross-compiles the whitelist-bypass headless VK "creator" binary
# (linux/arm64, static, CGO disabled) from a pinned upstream commit and
# emits it + a BUILD_MANIFEST into build/covert/dist/ (gitignored).
#
# Runs on the dev Mac. Requires: git, go (with GOOS=linux/GOARCH=arm64
# cross-compile support — no CGO needed), file, shasum (not sha256sum —
# macOS has no sha256sum).
#
# Usage: dev/build-covert-creator.sh
# Env overrides (mainly for testing):
#   UPSTREAM_DIR   - path to the upstream sparse clone
#                     (default: /Users/jonnik/amnezia-external/whitelist-bypass)
#   UPSTREAM_URL    - git remote to clone from if UPSTREAM_DIR is absent
#                     (default: https://github.com/kulikov0/whitelist-bypass.git)
#   UPSTREAM_SHA    - pinned upstream commit (default: the project pin below)
#   OUT_DIR         - output dir for the artifact + manifest
#                     (default: build/covert/dist, relative to the repo root)

set -eu

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

UPSTREAM_DIR="${UPSTREAM_DIR:-/Users/jonnik/amnezia-external/whitelist-bypass}"
UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/kulikov0/whitelist-bypass.git}"
UPSTREAM_SHA="${UPSTREAM_SHA:-89d7a474b7aca6cce664280e6feeaeca2706733b}"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/build/covert/dist}"

ARTIFACT_NAME="amnezia-covert-creator"

# ---------------------------------------------------------------------------
# 1. Ensure the upstream sparse checkout exists and is at the pinned SHA.
#    Must include BOTH relay/ and headless/vk (headless/vk/go.mod has
#    `replace whitelist-bypass/relay => ../../relay`, so headless/vk alone
#    cannot build).
# ---------------------------------------------------------------------------

if [ ! -d "$UPSTREAM_DIR/.git" ]; then
	echo "==> Upstream clone not found at $UPSTREAM_DIR — cloning (sparse: relay, headless)"
	git clone --filter=blob:none --sparse "$UPSTREAM_URL" "$UPSTREAM_DIR"
	( cd "$UPSTREAM_DIR" && git sparse-checkout set relay headless )
fi

echo "==> Fetching upstream and checking out pinned SHA $UPSTREAM_SHA"
( cd "$UPSTREAM_DIR" && git fetch origin "$UPSTREAM_SHA" 2>/dev/null || : )
( cd "$UPSTREAM_DIR" && git checkout --quiet "$UPSTREAM_SHA" )

ACTUAL_SHA="$(cd "$UPSTREAM_DIR" && git rev-parse HEAD)"
if [ "$ACTUAL_SHA" != "$UPSTREAM_SHA" ]; then
	echo "FATAL: upstream checkout landed on $ACTUAL_SHA, expected pinned $UPSTREAM_SHA" >&2
	exit 1
fi

if [ ! -d "$UPSTREAM_DIR/relay" ]; then
	echo "FATAL: $UPSTREAM_DIR/relay is missing — headless/vk's go.mod replace directive" \
		"(replace whitelist-bypass/relay => ../../relay) cannot resolve without it" >&2
	exit 1
fi

if [ ! -d "$UPSTREAM_DIR/headless/vk" ]; then
	echo "FATAL: $UPSTREAM_DIR/headless/vk is missing from the sparse checkout" >&2
	exit 1
fi

# ---------------------------------------------------------------------------
# 2. Build. Mirror upstream's own build-headless.sh invocation for the vk
#    creator (`go -C headless/vk build -trimpath -ldflags="-s -w" -o ... .`),
#    cross-compiled for the router.
# ---------------------------------------------------------------------------

mkdir -p "$OUT_DIR"
ARTIFACT_PATH="$OUT_DIR/$ARTIFACT_NAME"

echo "==> Building headless/vk creator for linux/arm64 (CGO disabled)"
GOOS=linux GOARCH=arm64 CGO_ENABLED=0 \
	go -C "$UPSTREAM_DIR/headless/vk" build -trimpath -ldflags="-s -w" \
	-o "$ARTIFACT_PATH" .

if [ ! -f "$ARTIFACT_PATH" ]; then
	echo "FATAL: build did not produce $ARTIFACT_PATH" >&2
	exit 1
fi

# ---------------------------------------------------------------------------
# 3. Assert the artifact is a static ARM aarch64 ELF (absence of
#    GOOS/GOARCH silently produces a darwin Mach-O — this catches it).
# ---------------------------------------------------------------------------

FILE_OUTPUT="$(file "$ARTIFACT_PATH")"
echo "==> $FILE_OUTPUT"

case "$FILE_OUTPUT" in
*ELF*aarch64*) : ;;
*)
	echo "FATAL: artifact is not an ELF aarch64 binary: $FILE_OUTPUT" >&2
	exit 1
	;;
esac

# ---------------------------------------------------------------------------
# 4. Checksum (shasum -a 256 — macOS has no sha256sum) and emit the manifest.
# ---------------------------------------------------------------------------

ARTIFACT_SHA256="$(shasum -a 256 "$ARTIFACT_PATH" | awk '{print $1}')"
GO_VERSION="$(go version | awk '{print $3}')"

if [ -z "$UPSTREAM_SHA" ] || [ -z "$GO_VERSION" ] || [ -z "$ARTIFACT_SHA256" ]; then
	echo "FATAL: one or more manifest fields are empty" \
		"(upstream_sha=$UPSTREAM_SHA go_version=$GO_VERSION artifact_sha256=$ARTIFACT_SHA256)" >&2
	exit 1
fi

MANIFEST_PATH="$OUT_DIR/BUILD_MANIFEST"
{
	echo "upstream_sha=$UPSTREAM_SHA"
	echo "go_version=$GO_VERSION"
	echo "artifact_sha256=$ARTIFACT_SHA256"
} >"$MANIFEST_PATH"

echo "==> Wrote $MANIFEST_PATH"
cat "$MANIFEST_PATH"

echo "==> Done: $ARTIFACT_PATH"
