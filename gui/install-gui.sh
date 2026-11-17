#!/bin/sh
# Install (or remove) the desktop GUI on Bazzite / Fedora Atomic.
#
#   sudo ./install-gui.sh        system install: helper, sudo rule, binary,
#                                icon and menu entry under /usr/local
#   ./install-gui.sh --user      current user only: binary, icon and menu entry
#                                in ~/.local — no root, no privileged actions
#   sudo ./install-gui.sh --remove   remove the system files
#   ./install-gui.sh --remove --user remove the user files
#   ./install-gui.sh PATH        install a specific binary (system)
#
# /usr is read-only on an ostree system, so everything lands in /usr/local,
# which is a writable symlink to /var/usrlocal. polkit only reads actions from
# /usr/share, so the root helper is authorised by a sudo drop-in instead.
#
# Build the binary first, as yourself: cd gui && cargo build --release
set -eu

here=$(cd "$(dirname "$0")" && pwd)
DESTDIR=${DESTDIR:-}
scope=system
action=install
bin=

for arg in "$@"; do
  case $arg in
    --user) scope=user ;;
    --remove) action=remove ;;
    --help|-h) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "unknown option: $arg" >&2; exit 2 ;;
    *) bin=$arg ;;
  esac
done

if [ "$scope" = user ]; then
  prefix=$HOME/.local
  helper=
  sudoers=
else
  prefix=${DESTDIR}/usr/local
  helper=${DESTDIR}/usr/local/bin/zapret-arch-helper
  sudoers=${DESTDIR}/etc/sudoers.d/zapret-arch-gui
fi

binary=$prefix/bin/zapret-arch-gui
icon=$prefix/share/icons/hicolor/scalable/apps/ru.suwkie.zapret-arch.svg
desktop=$prefix/share/applications/ru.suwkie.zapret-arch.desktop

if [ "$scope" = system ] && [ -z "$DESTDIR" ] && [ "$(id -u)" -ne 0 ]; then
  echo "run as root: sudo $0  (or --user for a menu entry in ~/.local)" >&2
  exit 1
fi

if [ "$action" = remove ]; then
  rm -f "$binary" "$icon" "$desktop" \
        "$prefix"/share/icons/hicolor/*/apps/ru.suwkie.zapret-arch.png
  [ -n "$helper" ] && rm -f "$helper" "$sudoers"
  echo "removed the desktop GUI ($scope)"
  exit 0
fi

bin=${bin:-$here/target/release/zapret-arch-gui}
[ -x "$bin" ] || { echo "build first: cargo build --release (in $here)" >&2; exit 3; }

install -Dm755 "$bin" "$binary"
install -Dm644 "$here/ru.suwkie.zapret-arch.svg" "$icon"
install -Dm644 "$here/ru.suwkie.zapret-arch.desktop" "$desktop"

# Raster fallbacks: some panels ask for a fixed size and will not scale an SVG.
if command -v rsvg-convert >/dev/null; then
  for size in 16 22 24 32 48 64 128 256; do
    dir=$prefix/share/icons/hicolor/${size}x${size}/apps
    install -d "$dir"
    rsvg-convert -w "$size" -h "$size" "$here/ru.suwkie.zapret-arch.svg" \
      -o "$dir/ru.suwkie.zapret-arch.png" 2>/dev/null || true
  done
fi

if [ -n "$helper" ]; then
  install -Dm755 "$here/helper/zapret-arch-helper" "$helper"
  # sudo gives the helper a clean environment and a fixed absolute path; the
  # helper itself validates every argument.
  install -d "$(dirname "$sudoers")"
  # Named for the user who ran the installer, not for every account on the box.
  who=${SUDO_USER:-%wheel}
  printf '%s ALL=(root) NOPASSWD: %s\n' "$who" "/usr/local/bin/zapret-arch-helper" \
    > "$sudoers"
  chmod 0440 "$sudoers"
  # /usr/local/bin is bin_t already; relabel only if this image says otherwise.
  if command -v getenforce >/dev/null && [ "$(getenforce 2>/dev/null)" = Enforcing ]; then
    chcon -t bin_t "$helper" 2>/dev/null || true
  fi
fi

# Absolute paths in the entry: ~/.local/bin is not on every PATH, and a themed
# icon name is not yet in the cache the first time the menu reads it.
esc() { printf '%s' "$1" | sed 's/[&|\\]/\\&/g'; }
bin_esc=$(esc "$binary")
icon_esc=$(esc "$icon")
sed -i -e "s|^Exec=zapret-arch-gui$|Exec=$bin_esc|" \
       -e "s|^TryExec=zapret-arch-gui$|TryExec=$bin_esc|" \
       -e "s|^Icon=ru.suwkie.zapret-arch$|Icon=$icon_esc|" "$desktop"

if [ -z "$DESTDIR" ] && command -v update-desktop-database >/dev/null; then
  update-desktop-database -q "$prefix/share/applications" 2>/dev/null || true
fi
if [ -z "$DESTDIR" ] && command -v gtk-update-icon-cache >/dev/null; then
  gtk-update-icon-cache -q -t "$prefix/share/icons/hicolor" 2>/dev/null || true
fi

echo "installed: $binary ($scope)"
