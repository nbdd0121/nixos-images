#!/bin/sh

set -ex
# provided by nix
init="@init@"
kernelParams="@kernelParams@"

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
INITRD_TMP=$(TMPDIR=$SCRIPT_DIR mktemp -d)

cd "$INITRD_TMP"
cleanup() {
  rm -rf "$INITRD_TMP"
}
trap cleanup EXIT
mkdir -p ssh

extractPubKeys() {
  home="$1"
  for file in .ssh/authorized_keys .ssh/authorized_keys2; do
    key="$home/$file"
    if test -e "$key"; then
      # workaround for debian shenanigans
      grep -o '\(ssh-[^ ]* .*\)' "$key" >> ssh/authorized_keys || true
    fi
  done
}
extractPubKeys /root

if test -n "${SUDO_USER-}"; then
  sudo_home=$(sh -c "echo ~$SUDO_USER")
  extractPubKeys "$sudo_home"
fi

# Typically for NixOS
if test -e /etc/ssh/authorized_keys.d/root; then
  cat /etc/ssh/authorized_keys.d/root >> ssh/authorized_keys
fi
if test -n "${SUDO_USER-}" && test -e "/etc/ssh/authorized_keys.d/$SUDO_USER"; then
  cat "/etc/ssh/authorized_keys.d/$SUDO_USER" >> ssh/authorized_keys
fi
for p in /etc/ssh/ssh_host_*; do
  test -e "$p" || continue
  cp -a "$p" ssh
done

# save the networking config for later use
"$SCRIPT_DIR/ip" --json addr > addrs.json

"$SCRIPT_DIR/ip" -4 --json route > routes-v4.json
"$SCRIPT_DIR/ip" -6 --json route > routes-v6.json

find . | cpio -o -H newc | gzip -9 >> "$SCRIPT_DIR/initrd"

# Dropped --kexec-syscall-auto because it broke on GCP...
"$SCRIPT_DIR/kexec" --load "$SCRIPT_DIR/bzImage" \
  --initrd="$SCRIPT_DIR/initrd" \
  --command-line "init=$init $kernelParams"

# Disconnect our background kexec from the terminal
echo "machine will boot into nixos in in 6s..."
if test -e /dev/kmsg; then
  # this makes logging visible in `dmesg`, or the system consol or tools like journald
  exec > /dev/kmsg 2>&1
else
  exec > /dev/null 2>&1
fi
# We will kexec in background so we can cleanly finish the script before the hosts go down.
# This makes integration with tools like terraform easier.
nohup sh -c "sleep 6 && '$SCRIPT_DIR/kexec' -e" &