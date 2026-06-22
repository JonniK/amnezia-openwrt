#!/bin/sh
# Boot the OpenWrt test VM headless. Serial console + QEMU monitor are exposed
# on unix sockets (so console.sh can drive first-boot provisioning), and the
# WAN NIC is user-mode NAT with host:2222 forwarded to VM:22 for SSH.
#
#   dev/vm/run-vm.sh          # boot, blocks (serial mirrored to run/serial.log)
#   dev/vm/run-vm.sh &        # boot in background
#   dev/vm/run-vm.sh stop     # kill a running VM
set -eu
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/lib.sh"

if [ "${1:-}" = "stop" ]; then
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    kill "$(cat "$PIDFILE")" && vm_log "stopped VM pid $(cat "$PIDFILE")"
  else
    vm_log "no running VM"
  fi
  rm -f "$PIDFILE" "$SERIAL_SOCK" "$MON_SOCK"
  exit 0
fi

[ -f "$DISK" ]     || { echo "FATAL: disk missing; run fetch-image.sh first" >&2; exit 1; }
[ -f "$EFI_CODE" ] || { echo "FATAL: firmware missing; run fetch-image.sh first" >&2; exit 1; }
command -v qemu-system-aarch64 >/dev/null || { echo "FATAL: qemu-system-aarch64 not in PATH" >&2; exit 1; }

if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  echo "FATAL: VM already running (pid $(cat "$PIDFILE")); run 'run-vm.sh stop' first" >&2; exit 1
fi

rm -f "$SERIAL_SOCK" "$MON_SOCK" "$SERIAL_LOG"
vm_log "booting OpenWrt $OPENWRT_VER (serial: $SERIAL_SOCK, ssh: $SSH_HOST:$SSH_PORT)"

# -serial unix socket: console.sh attaches for provisioning; also tee'd to log.
# -netdev user WAN: 10.0.2.0/24 NAT to host internet (reaches real endpoints),
#   hostfwd exposes dropbear on the host for scriptable SSH.
exec qemu-system-aarch64 \
  -name openwrt-test \
  -machine virt -accel hvf -cpu host -smp "$VM_SMP" -m "$VM_MEM" \
  -drive if=pflash,format=raw,readonly=on,file="$EFI_CODE" \
  -drive if=pflash,format=raw,file="$EFI_VARS" \
  -drive if=virtio,format=qcow2,file="$DISK" \
  -device virtio-net-pci,netdev=wan \
  -netdev user,id=wan,hostfwd=tcp:"$SSH_HOST":"$SSH_PORT"-:22 \
  -display none \
  -chardev "socket,id=serial0,path=$SERIAL_SOCK,server=on,wait=off,logfile=$SERIAL_LOG,logappend=off" \
  -serial chardev:serial0 \
  -monitor "unix:$MON_SOCK,server,nowait" \
  -pidfile "$PIDFILE"
