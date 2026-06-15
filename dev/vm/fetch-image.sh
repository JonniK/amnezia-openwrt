#!/bin/sh
# One-time setup: ensure the OpenWrt image is present + decompressed, copy the
# EFI firmware, and build a fresh qcow2 overlay disk so each run starts from a
# clean pristine rootfs without re-downloading. Re-run to reset the VM disk.
set -eu
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/lib.sh"

mkdir -p "$IMAGES" "$RUN"

if [ ! -f "$IMG_RAW" ]; then
  if [ ! -f "$IMG_GZ" ]; then
    vm_log "downloading $IMG_URL"
    curl -fL --retry 3 -o "$IMG_GZ" "$IMG_URL"
  fi
  vm_log "decompressing $(basename "$IMG_GZ")"
  gunzip -kf "$IMG_GZ"
fi
[ -f "$IMG_RAW" ] || { echo "FATAL: raw image missing: $IMG_RAW" >&2; exit 1; }

# EFI firmware: code is read-only; vars must be a writable per-run copy.
[ -f "$EFI_CODE_SRC" ] || { echo "FATAL: edk2 code firmware not found: $EFI_CODE_SRC (is qemu installed?)" >&2; exit 1; }
cp -f "$EFI_CODE_SRC" "$EFI_CODE"
if [ -f "$EFI_VARS_SRC" ]; then
  cp -f "$EFI_VARS_SRC" "$EFI_VARS"
else
  # Fallback: a blank 64MiB vars store (edk2 pflash images are 64MiB).
  vm_log "edk2 vars template missing; creating blank 64MiB vars store"
  dd if=/dev/zero of="$EFI_VARS" bs=1m count=64 2>/dev/null
fi

# Fresh overlay disk backed by the pristine image: fast, resettable, leaves the
# downloaded image untouched. Give it headroom for installed packages.
vm_log "creating fresh overlay disk $DISK (backing: $(basename "$IMG_RAW"))"
rm -f "$DISK"
qemu-img create -f qcow2 -F raw -b "$IMG_RAW" "$DISK" 8G >/dev/null

vm_log "ready: image=$IMG_RAW disk=$DISK firmware=$EFI_CODE"
