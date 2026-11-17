#!/usr/bin/env bash
# Remove zapret-arch. Touches only its own prefix and unit.
set -euo pipefail

SCRIPT_PATH=$(readlink -f -- "${BASH_SOURCE[0]}")
SCRIPT_DIR=$(cd -- "$(dirname -- "$SCRIPT_PATH")" && pwd)
if [[ $(basename "$SCRIPT_DIR") == app ]]; then
  DEFAULT_PREFIX=$(dirname "$SCRIPT_DIR")
else
  DEFAULT_PREFIX=/usr/local/lib/zapret-arch
fi
PREFIX=${PREFIX:-$DEFAULT_PREFIX}
PREFIX=$(realpath -m -- "$PREFIX")

[[ -n $PREFIX && $PREFIX != / ]] || { echo "Refusing to remove $PREFIX" >&2; exit 1; }
[[ $(id -u) -eq 0 ]] || { echo "Run as root: sudo ./uninstall.sh" >&2; exit 1; }
[[ -f $PREFIX/.zapret-arch || -f $PREFIX/app/zapret-arch ]] || {
  echo "Not a zapret-arch install: $PREFIX (marker missing)" >&2
  exit 1
}

NFQWS=$PREFIX/engine/nfq/nfqws
NFQWS_PATTERN=${NFQWS%nfqws}[n]fqws
if [[ $PREFIX == /usr/local/lib/zapret-arch ]]; then
  systemctl disable --now zapret-arch.service >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/zapret-arch.service
  systemctl daemon-reload 2>/dev/null || true
fi

pkill -f "$NFQWS_PATTERN" 2>/dev/null || true
sleep 0.5
if pgrep -f "$NFQWS_PATTERN" >/dev/null; then
  echo "nfqws from $PREFIX is still running; refusing to delete files" >&2
  exit 1
fi
# Only the default-prefix install owns table zapret_arch. A staging tree
# must never delete the production table.
if [[ $PREFIX == /usr/local/lib/zapret-arch ]] && nft list table inet zapret_arch >/dev/null 2>&1; then
  nft delete table inet zapret_arch 2>/dev/null || true
fi

target=$(readlink -f -- /usr/local/bin/zapret-arch 2>/dev/null || true)
case $target in "$PREFIX"/*) rm -f /usr/local/bin/zapret-arch ;; esac
target=$(readlink -f -- /usr/local/bin/arch-zapret 2>/dev/null || true)
case $target in "$PREFIX"/*) rm -f /usr/local/bin/arch-zapret ;; esac

# Undo the /etc/hosts pins before the tree that owns the script is deleted.
# The GUI lives in /usr/local, outside the prefix, so remove it unconditionally:
# a leftover sudo rule would keep granting root to a deleted helper.
if [[ $PREFIX == /usr/local/lib/zapret-arch ]]; then
  rm -f /usr/local/bin/zapret-arch-gui \
        /usr/local/bin/zapret-arch-helper \
        /etc/sudoers.d/zapret-arch-gui \
        /usr/local/share/applications/ru.suwkie.zapret-arch.desktop \
        /usr/local/share/icons/hicolor/*/apps/ru.suwkie.zapret-arch.svg \
        /usr/local/share/icons/hicolor/*/apps/ru.suwkie.zapret-arch.png
fi

if [[ $PREFIX == /usr/local/lib/zapret-arch && -x $PREFIX/app/extras/hosts-pin.sh ]]; then
  "$PREFIX/app/extras/hosts-pin.sh" minecraft off || true
  "$PREFIX/app/extras/hosts-pin.sh" roblox off || true
fi

rm -rf -- "$PREFIX"
echo "Removed zapret-arch from $PREFIX"
