#!/usr/bin/env bash
# Install zapret-arch: pinned upstream engine + pinned Flowseal strategies.
set -euo pipefail

DEFAULT_PREFIX=/usr/local/lib/zapret-arch
PREFIX=$DEFAULT_PREFIX
WITH_SYSTEMD=auto
START=0
WITH_GUI=auto

usage() {
  cat <<'EOF'
Usage: sudo ./install.sh [--prefix DIR] [--no-systemd] [--start]

  --prefix DIR    Install under DIR (default: /usr/local/lib/zapret-arch)
  --no-systemd    Do not install the systemd unit (staging/testing)
  --start         Start the service after installing
  --with-gui      Require the desktop GUI (fails the install if it is not built)
  --no-gui        Do not install the desktop GUI even when it is built
EOF
}

# --prefix is for unprivileged staging: run without sudo and the installer
# selects --no-systemd automatically. A root install into a prefix (or any
# ancestor) that is not root-owned and not group/world-writable is refused.

while [[ $# -gt 0 ]]; do
  case $1 in
    --prefix) PREFIX=${2:?--prefix needs a directory}; shift 2 ;;
    --no-systemd) WITH_SYSTEMD=0; shift ;;
    --start) START=1; shift ;;
    --with-gui) WITH_GUI=1; shift ;;
    --no-gui) WITH_GUI=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

PREFIX=$(realpath -m -- "$PREFIX")
[[ $PREFIX =~ ^[A-Za-z0-9_./-]+$ ]] || { echo "Prefix may only contain letters, digits, dot, slash, dash, underscore" >&2; exit 2; }
[[ $PREFIX != / ]] || { echo "Refusing to install to /" >&2; exit 2; }
[[ $(id -u) -eq 0 || $PREFIX != "$DEFAULT_PREFIX" ]] || {
  echo "Root is required for the default install. Re-run with sudo, or use --prefix for staging." >&2
  exit 2
}

export ZAPRET_HOME=$PREFIX
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/strategy.sh"

GUI_BIN=${GUI_BIN:-$SCRIPT_DIR/gui/target/release/zapret-arch-gui}
if [[ $WITH_GUI == 1 && ! -x $GUI_BIN ]]; then
  die "The desktop GUI is not built. Run: (cd $SCRIPT_DIR/gui && cargo build --release)"
fi

ENGINE_VERSION=v72.13
ENGINE_SHA256=25c74e6c5f48963fa244c2955e76694a07c39447245a0457e2efdc74b3317e68
ENGINE_URL="https://github.com/bol-van/zapret/releases/download/$ENGINE_VERSION/zapret-$ENGINE_VERSION.tar.gz"

# Pinned commit; re-run with updated ref/hash to pick up new Flowseal
# strategies. Pinning keeps a compromised upstream commit out of a root
# install and makes installs reproducible.
FLOWSEAL_REF=2401b7a13837139b0265632464ba563dddbf80d8
FLOWSEAL_SHA256=f7752c41a994d7ce887cc0c2ae7ffe7935d6e2f15532ae71f403ea70cf149104
FLOWSEAL_URL="https://codeload.github.com/Flowseal/zapret-discord-youtube/tar.gz/$FLOWSEAL_REF"

case $(uname -m) in
  x86_64) ARCH=x86_64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  armv7l|armv6l) ARCH=arm ;;
  i686|i386) ARCH=x86 ;;
  *) die "Unsupported architecture: $(uname -m)" ;;
esac

check_dependencies() {
  local missing=() cmd
  for cmd in curl tar gzip sha256sum nft flock; do
    command -v "$cmd" >/dev/null || missing+=("$cmd")
  done
  if (( ${#missing[@]} )); then
    warn "Missing dependencies: ${missing[*]}"
    if command -v pacman >/dev/null; then
      [[ $(id -u) -eq 0 ]] || die "Install them first: sudo pacman -S --needed nftables curl util-linux"
      log "Installing nftables and curl"
      pacman -S --needed --noconfirm nftables curl util-linux
    elif command -v rpm-ostree >/dev/null; then
      # /usr is immutable: packages are layered and need a reboot to appear.
      die "Missing: ${missing[*]}. Layer them: sudo rpm-ostree install nftables curl util-linux && sudo systemctl reboot"
    else
      die "Missing: ${missing[*]}. Install them and re-run."
    fi
  fi
}

# /var/lib is var_lib_t and systemd's init_t may not execute from it, so the
# tree has to carry bin_t the way /usr/bin does. rpm-ostree systems only.
# `zapret-arch update` re-runs this installer, so the label is reapplied then.
selinux_relabel() {
  command -v getenforce >/dev/null || return 0
  [[ $(getenforce 2>/dev/null) == Enforcing ]] || return 0
  if chcon -R -t bin_t "$PREFIX" 2>/dev/null; then
    log "SELinux: labelled $PREFIX as bin_t"
  else
    warn "Could not relabel $PREFIX; the unit may fail with 203/EXEC"
  fi
}

download() {
  local url=$1 out=$2
  log "Downloading $(basename "$out")"
  curl -fsSL --retry 3 --connect-timeout 15 --max-time 300 \
    --proto '=https' --proto-redir '=https' --max-redirs 3 --max-filesize 200M \
    -o "$out" "$url"
}

# Refuse to take over a directory this project does not own.
if [[ -d $PREFIX ]] && [[ -n $(ls -A -- "$PREFIX" 2>/dev/null) ]] \
  && [[ ! -f $PREFIX/.zapret-arch && ! -f $PREFIX/app/zapret-arch ]]; then
  die "Refusing to install into non-empty directory not owned by zapret-arch: $PREFIX"
fi

if [[ $WITH_SYSTEMD == auto ]]; then
  if [[ $(id -u) -eq 0 && $PREFIX == "$DEFAULT_PREFIX" ]]; then WITH_SYSTEMD=1; else WITH_SYSTEMD=0; fi
fi

if [[ $WITH_SYSTEMD == 0 && $PREFIX == "$DEFAULT_PREFIX" ]] \
  && systemctl is-active --quiet "$UNIT_NAME" 2>/dev/null; then
  die "$UNIT_NAME is running. Stop it first: sudo systemctl stop $UNIT_NAME"
fi

check_dependencies

mkdir -p "$PREFIX"
if [[ $(id -u) -eq 0 ]]; then
  owner=$(stat -c %u -- "$PREFIX") || die "Cannot stat prefix: $PREFIX"
  mode=$(stat -c %a -- "$PREFIX") || die "Cannot stat prefix: $PREFIX"
  [[ -n $owner && $owner -eq 0 ]] \
    || die "Refusing to install as root into a non-root-owned prefix: $PREFIX"
  (( (8#${mode} & 8#22) == 0 )) \
    || die "Refusing to install as root into a group/world-writable prefix: $PREFIX"
  dir=$(dirname -- "$PREFIX")
  while :; do
    d_owner=$(stat -c %u -- "$dir") || die "Cannot stat prefix ancestor: $dir"
    d_mode=$(stat -c %a -- "$dir") || die "Cannot stat prefix ancestor: $dir"
    [[ -n $d_owner && $d_owner -eq 0 ]] \
      || die "Refusing to install as root under a non-root-owned ancestor: $dir"
    (( (8#${d_mode} & 8#22) == 0 )) \
      || die "Refusing to install as root under a group/world-writable ancestor: $dir"
    [[ $dir == / ]] && break
    dir=$(dirname -- "$dir")
  done
fi
exec 9>"$PREFIX/.zapret-install.lock"
flock -n 9 || die "Another install is already running for $PREFIX"
: > "$PREFIX/.zapret-arch"

TMP=$(mktemp -d)
ENGINE_OLD=$PREFIX/engine.old
PROFILES_OLD=$PREFIX/profiles.old
UNIT_FILE=/etc/systemd/system/$UNIT_NAME
UNIT_BACKUP=$UNIT_FILE.zapret-arch-old
WAS_ACTIVE=0
STOPPED_SERVICE=0
HAD_INSTALL=0
ROLLBACK=0
UNIT_WRITTEN=0
OLD_STRATEGY=$(current_strategy)
OLD_GAMES=$(current_games)
OLD_VOICE=$(current_voice)
OLD_MC=$(current_minecraft)
NFQWS_PATTERN="$ENGINE_DIR/nfq/[n]fqws"

cleanup() {
  local rc=$?
  set +e
  trap - EXIT
  if (( ROLLBACK )); then
    warn "Install failed; restoring the previous installation"
    if [[ -d $ENGINE_OLD ]]; then
      rm -rf "$PREFIX/engine"
      mv "$ENGINE_OLD" "$PREFIX/engine"
    elif (( HAD_INSTALL == 0 )); then
      rm -rf "$PREFIX/engine"
    fi
    if [[ -d $PROFILES_OLD ]]; then
      rm -rf "$PROFILES_DIR"
      mv "$PROFILES_OLD" "$PROFILES_DIR"
    elif (( HAD_INSTALL == 0 )); then
      rm -rf "$PROFILES_DIR"
    fi
    if [[ -n $OLD_STRATEGY ]]; then set_strategy "$OLD_STRATEGY"; else rm -f "$STATE_DIR/strategy"; fi
    set_games "$OLD_GAMES"
    set_voice "$OLD_VOICE"
    set_minecraft "$OLD_MC"
    if (( UNIT_WRITTEN )); then
      if [[ -f $UNIT_BACKUP ]]; then mv "$UNIT_BACKUP" "$UNIT_FILE"; else rm -f "$UNIT_FILE"; fi
      systemctl daemon-reload >/dev/null 2>&1
    fi
    if (( WAS_ACTIVE )); then
      systemctl restart "$UNIT_NAME" >/dev/null 2>&1
      for _ in {1..20}; do
        systemctl is-active --quiet "$UNIT_NAME" \
          && pgrep -f "$NFQWS_PATTERN" >/dev/null \
          && nft_queue_loaded \
          && break
        sleep 0.3
      done
      systemctl is-active --quiet "$UNIT_NAME" \
        || warn "Previous install restored, but its service is not running"
    fi
    if (( HAD_INSTALL == 0 )) && [[ $PREFIX == "$DEFAULT_PREFIX" ]]; then
      rm -f /usr/local/bin/zapret-arch
      rm -f /usr/local/bin/arch-zapret
    fi
    warn "Previous installation restored"
  elif (( STOPPED_SERVICE )) && ! pgrep -f "$NFQWS_PATTERN" >/dev/null; then
    # The service was stopped before rollback was armed; put it back only if
    # its daemon is actually gone.
    systemctl start "$UNIT_NAME" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP"
  exit "$rc"
}
trap cleanup EXIT

download "$ENGINE_URL" "$TMP/zapret.tar.gz"
echo "$ENGINE_SHA256  $TMP/zapret.tar.gz" | sha256sum -c - >/dev/null \
  || die "Engine checksum mismatch (expected $ENGINE_VERSION)"
download "$FLOWSEAL_URL" "$TMP/flowseal.tar.gz"
echo "$FLOWSEAL_SHA256  $TMP/flowseal.tar.gz" | sha256sum -c - >/dev/null \
  || die "Flowseal checksum mismatch (expected $FLOWSEAL_REF)"

mkdir -p "$TMP/engine" "$TMP/flowseal"
log "Extracting engine $ENGINE_VERSION"
tar --no-same-owner --no-same-permissions -xzf "$TMP/zapret.tar.gz" \
  -C "$TMP/engine" --strip-components=1
log "Extracting Flowseal strategies"
tar --no-same-owner --no-same-permissions -xzf "$TMP/flowseal.tar.gz" \
  -C "$TMP/flowseal" --strip-components=1

[[ -x "$TMP/engine/binaries/linux-$ARCH/nfqws" ]] || die "Engine has no nfqws for linux-$ARCH"
[[ -f "$TMP/engine/config.default" ]] || die "Engine config.default missing"
[[ -d "$TMP/flowseal/bin" && -d "$TMP/flowseal/lists" ]] || die "Flowseal asset layout changed"
compgen -G "$TMP/flowseal/general*.bat" >/dev/null || die "Flowseal strategies missing"
if [[ -n $(find "$TMP/flowseal" -type l -print -quit) ]]; then
  die "Flowseal archive contains symlinks; refusing to copy as root"
fi

# Never touch a foreign nfqws (for example the old /opt/zapret install).
# A custom prefix is staging-only and cannot affect the live service.
if [[ $PREFIX == "$DEFAULT_PREFIX" ]]; then
  foreign=""
  for pid in $(pgrep -x nfqws 2>/dev/null); do
    exe=$(readlink "/proc/$pid/exe" 2>/dev/null || true)
    case $exe in
      "$PREFIX/engine/binaries/linux-$ARCH/nfqws"|"$PREFIX/engine/binaries/linux-$ARCH/nfqws (deleted)") ;;
      *) foreign+="$pid ${exe:-unknown}; " ;;
    esac
  done
  if [[ -n $foreign ]]; then
    die "Another nfqws is running: $foreign Stop it first (for example: sudo systemctl stop zapret.service)."
  fi
fi

if [[ $WITH_SYSTEMD == 1 ]] && systemctl is-active --quiet "$UNIT_NAME" 2>/dev/null; then
  WAS_ACTIVE=1
  STOPPED_SERVICE=1
  systemctl stop "$UNIT_NAME" || true
  for _ in {1..10}; do
    pgrep -f "$NFQWS_PATTERN" >/dev/null || break
    sleep 0.3
  done
  pgrep -f "$NFQWS_PATTERN" >/dev/null \
    && die "Could not stop the running zapret-arch service"
fi
if [[ $WITH_SYSTEMD == 1 ]]; then
  for unit in zapret.service zapret_discord_youtube.service; do
    systemctl is-enabled --quiet "$unit" 2>/dev/null \
      && warn "$unit is enabled; it will be stopped and disabled after install"
  done
fi

log "Installing to $PREFIX"
rm -rf "$ENGINE_OLD" "$PROFILES_OLD"
ROLLBACK=1
if [[ -d $PREFIX/engine ]]; then
  HAD_INSTALL=1
  mv "$PREFIX/engine" "$ENGINE_OLD"
fi
if [[ -d $PROFILES_DIR ]]; then
  mv "$PROFILES_DIR" "$PROFILES_OLD"
fi

cp -a "$TMP/engine" "$PREFIX/engine"

# Upstream init expects built binaries at these paths.
ln -sfn "../binaries/linux-$ARCH/nfqws"   "$PREFIX/engine/nfq/nfqws"
ln -sfn "../binaries/linux-$ARCH/tpws"    "$PREFIX/engine/tpws/tpws"
ln -sfn "../binaries/linux-$ARCH/ip2net"  "$PREFIX/engine/ip2net/ip2net"
ln -sfn "../binaries/linux-$ARCH/mdig"    "$PREFIX/engine/mdig/mdig"
NFQWS_REAL=$(readlink -f -- "$ENGINE_DIR/nfq/nfqws")
NFQWS_PATTERN="$ENGINE_DIR/nfq/[n]fqws"

# Refresh generated assets; keep old fakes (restored profiles may need them),
# user lists and state.
rm -rf "$PREFIX/bats"
install -d "$FAKES_DIR" "$LISTS_DIR" "$PREFIX/bats" "$PROFILES_DIR" "$STATE_DIR" \
  "$PREFIX/app/lib" "$PREFIX/app/systemd" "$PREFIX/app/extras"

cp -- "$TMP/flowseal/bin/"*.bin "$FAKES_DIR/"
[[ -f $FAKES_DIR/tls_clienthello_4pda_to.bin ]] \
  || die "Flowseal fake tls_clienthello_4pda_to.bin is missing; the Minecraft profile would be invalid"
for file in "$TMP/flowseal/lists/"*.txt; do
  case $(basename "$file") in
    list-general-user.txt|list-exclude-user.txt|ipset-exclude-user.txt) continue ;;
  esac
  cp -- "$file" "$LISTS_DIR/"
done
for file in list-general-user.txt list-exclude-user.txt ipset-exclude-user.txt; do
  [[ -e $LISTS_DIR/$file ]] || : > "$LISTS_DIR/$file"
done
# Seed the preserved user list with the DPI-blocked Modrinth apex. Its
# subdomains (api/cdn/docs/www) work directly and are deliberately left out;
# a plain "modrinth.com" would desync them too. "^" means exact host.
for domain in '^modrinth.com' 'steamcloud-frf.s3.dualstack.eu-central-1.amazonaws.com' \
              'scdn.co' 'spotify.com'; do
  grep -qxF -- "$domain" "$LISTS_DIR/list-general-user.txt" \
    || printf '%s\n' "$domain" >> "$LISTS_DIR/list-general-user.txt"
done
cp -- "$TMP/flowseal/"general*.bat "$PREFIX/bats/"
cp -- "$TMP/flowseal/utils/targets.txt" "$PREFIX/targets.txt"

build_profiles "$PREFIX/bats" "$FAKES_DIR" "$LISTS_DIR" "$PROFILES_DIR"
validate_profiles "$PROFILES_DIR" "$ENGINE_DIR/nfq/nfqws"

strategy=$OLD_STRATEGY
if ! profile_exists "$strategy"; then
  strategy=general
  profile_exists "$strategy" || {
    for profile in "$PROFILES_DIR"/*.opt; do
      strategy=$(basename "$profile" .opt)
      break
    done
  }
fi
games=$(current_games)
voice=$(current_voice)
minecraft=$(current_minecraft)
write_config "$strategy" "$games" "$voice" "$minecraft"
validate_effective_config "$strategy" "$games" "$voice" on \
  || die "Generated config failed nfqws validation (minecraft on)"
validate_effective_config "$strategy" "$games" "$voice" off \
  || die "Generated config failed nfqws validation (minecraft off)"
set_strategy "$strategy"
set_games "$games"
set_voice "$voice"
set_minecraft "$minecraft"
# A single-file installer runs from a temporary directory that is gone by the
# time `zapret-arch update` is called; it asks for the installed copy instead.
source_dir=${ZAPRET_SOURCE_DIR:-$SCRIPT_DIR}
[[ $source_dir == self ]] && source_dir=$PREFIX/app
printf '%s\n' "$source_dir" > "$STATE_DIR/source"

install -m 0755 "$SCRIPT_DIR/zapret-arch" "$PREFIX/app/zapret-arch"
install -m 0644 "$SCRIPT_DIR/lib/"*.sh "$PREFIX/app/lib/"
install -m 0644 "$SCRIPT_DIR/systemd/zapret-arch.service" "$PREFIX/app/systemd/"
install -m 0755 "$SCRIPT_DIR/extras/"*.sh "$PREFIX/app/extras/"
install -m 0755 "$SCRIPT_DIR/install.sh" "$SCRIPT_DIR/uninstall.sh" "$PREFIX/app/"

selinux_relabel

if [[ $WITH_SYSTEMD == 1 ]]; then
  if [[ -f $UNIT_FILE ]]; then cp -a "$UNIT_FILE" "$UNIT_BACKUP"; fi
  UNIT_WRITTEN=1
  sed -e "s|@PREFIX@|$PREFIX|g" \
      -e "s|@NFT_TABLE@|$NFT_TABLE|g" \
      -e "s|@NFQUEUE_NUM@|$NFQUEUE_NUM|g" \
      -e "s|@NFQWS_REAL@|$NFQWS_REAL|g" \
      "$SCRIPT_DIR/systemd/zapret-arch.service" > "$UNIT_FILE"
  chmod 0644 "$UNIT_FILE"
  systemctl daemon-reload
  systemctl enable "$UNIT_NAME" >/dev/null
  log "Installed systemd unit $UNIT_NAME (enabled)"

  if (( START || WAS_ACTIVE )); then
    systemctl restart "$UNIT_NAME" || true
    for _ in {1..20}; do
      systemctl is-active --quiet "$UNIT_NAME" \
        && pgrep -f "$NFQWS_PATTERN" >/dev/null \
        && nft_queue_loaded \
        && break
      sleep 0.3
    done
    if ! systemctl is-active --quiet "$UNIT_NAME" \
      || ! pgrep -f "$NFQWS_PATTERN" >/dev/null \
      || ! nft_queue_loaded; then
      journalctl -u "$UNIT_NAME" -n 20 --no-pager >&2 || true
      die "Service failed to start with the new configuration"
    fi
    log "Service is running"
  fi
else
  sed -e "s|@PREFIX@|$PREFIX|g" \
      -e "s|@NFT_TABLE@|$NFT_TABLE|g" \
      -e "s|@NFQUEUE_NUM@|$NFQUEUE_NUM|g" \
      -e "s|@NFQWS_REAL@|$NFQWS_REAL|g" \
      "$SCRIPT_DIR/systemd/zapret-arch.service" > "$PREFIX/zapret-arch.service"
  warn "systemd unit not installed (staging mode). Unit template: $PREFIX/zapret-arch.service"
fi

ROLLBACK=0
STOPPED_SERVICE=0
if [[ $PREFIX == "$DEFAULT_PREFIX" ]]; then
  ln -sfn "$PREFIX/app/zapret-arch" /usr/local/bin/zapret-arch \
    || warn "Could not update /usr/local/bin/zapret-arch"
  ln -sfn "$PREFIX/app/zapret-arch" /usr/local/bin/arch-zapret \
    || warn "Could not update /usr/local/bin/arch-zapret"
fi
rm -f "$UNIT_BACKUP"
rm -rf "$ENGINE_OLD" "$PROFILES_OLD"

# Two NFQUEUE setups cannot coexist safely. Keep the unit files, but stop and
# disable the known conflicting services so the next boot has one owner.
if [[ $WITH_SYSTEMD == 1 ]]; then
  for unit in zapret.service zapret_discord_youtube.service; do
    if systemctl is-enabled --quiet "$unit" 2>/dev/null \
      || systemctl is-active --quiet "$unit" 2>/dev/null; then
      warn "Stopping and disabling conflicting $unit (its files are untouched)"
      systemctl disable --now "$unit" >/dev/null 2>&1 || true
    fi
  done
fi

# Mojang/Minecraft hosts mostly resolve to an Azure Front Door address this ISP
# drops at TCP 443; pin them so the Modrinth App and skin texture loading work.
if [[ $PREFIX == "$DEFAULT_PREFIX" ]]; then
  if ! "$PREFIX/app/extras/minecraft-hosts.sh" on; then
    warn "Could not pin Mojang hosts; run: sudo zapret-arch hosts on"
  fi
fi

# Desktop GUI. Auto mode installs it whenever a release binary has been built,
# so `zapret-arch update` keeps an installed GUI current; --with-gui makes a
# missing binary an error instead of a silent skip.
if [[ $WITH_GUI != 0 && $PREFIX == "$DEFAULT_PREFIX" ]]; then
  if [[ -x $GUI_BIN ]]; then
    if "$SCRIPT_DIR/gui/install-gui.sh" "$GUI_BIN"; then
      chcon -t bin_t /usr/local/bin/zapret-arch-helper 2>/dev/null || true
      log "Desktop GUI installed: run zapret-arch gui"
    else
      warn "Could not install the desktop GUI; re-run: sudo $SCRIPT_DIR/gui/install-gui.sh"
    fi
  else
    log "Desktop GUI not built; skip it or run: (cd $SCRIPT_DIR/gui && cargo build --release)"
  fi
fi

log "Installed $(( $(find "$PROFILES_DIR" -name '*.opt' | wc -l) )) strategies under $PROFILES_DIR"
log "Current strategy: $strategy (games: $games, voice: $voice, minecraft: $minecraft)"
if [[ $voice == on ]]; then
  log "If Discord voice/screen share breaks: sudo zapret-arch voice off"
fi
if [[ $minecraft == off && $PREFIX == "$DEFAULT_PREFIX" ]]; then
  log "For Hypixel: sudo zapret-arch minecraft on"
fi
if [[ $WITH_SYSTEMD == 1 && $START -eq 0 && $WAS_ACTIVE -eq 0 ]]; then
  log "Start now with: sudo systemctl start $UNIT_NAME"
fi
log "Manage with: zapret-arch"
