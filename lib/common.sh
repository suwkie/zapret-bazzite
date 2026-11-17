#!/usr/bin/env bash
# Shared paths and helpers for zapret-arch. Sourced by all entrypoints.

ZAPRET_HOME=${ZAPRET_HOME:-/usr/local/lib/zapret-arch}
ENGINE_DIR=$ZAPRET_HOME/engine
FAKES_DIR=$ZAPRET_HOME/fakes
LISTS_DIR=$ZAPRET_HOME/lists
PROFILES_DIR=$ZAPRET_HOME/profiles
STATE_DIR=$ZAPRET_HOME/state
CONFIG_FILE=$ENGINE_DIR/config
UNIT_NAME=zapret-arch.service
GAME_PORTS=1024-65535
# Namespaced so an existing /opt/zapret install (queue 200, table "zapret")
# cannot collide with this one.
NFQUEUE_NUM=201
NFT_TABLE=zapret_arch

log()  { printf '[*] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die()  { printf '[x] %s\n' "$*" >&2; exit 1; }

require_root() {
  [[ $(id -u) -eq 0 ]] || die "Root is required. Re-run with sudo."
}

slugify() {
  local name=${1:-}
  name=${name##*/}
  printf '%s' "$name" | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/\.bat$//; s/[()]//g; s/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

current_strategy() {
  local file=$STATE_DIR/strategy
  [[ -f $file ]] && cat "$file"
  return 0
}

current_games() {
  local file=$STATE_DIR/games
  if [[ -f $file ]]; then cat "$file"; else echo off; fi
}

current_voice() {
  local file=$STATE_DIR/voice
  if [[ -f $file ]]; then cat "$file"; else echo on; fi
}

current_minecraft() {
  local file=$STATE_DIR/minecraft
  if [[ -f $file ]]; then cat "$file"; else echo off; fi
}

set_strategy() {
  mkdir -p "$STATE_DIR"
  printf '%s\n' "$1" > "$STATE_DIR/strategy"
}

set_games() {
  mkdir -p "$STATE_DIR"
  printf '%s\n' "$1" > "$STATE_DIR/games"
}

set_voice() {
  mkdir -p "$STATE_DIR"
  printf '%s\n' "$1" > "$STATE_DIR/voice"
}

set_minecraft() {
  mkdir -p "$STATE_DIR"
  printf '%s\n' "$1" > "$STATE_DIR/minecraft"
}

profile_exists() {
  [[ -n ${1:-} ]] || return 1
  [[ $1 =~ ^[a-z0-9][a-z0-9-]*$ ]] || return 1
  [[ -f $PROFILES_DIR/$1.opt ]]
}

valid_ports() {
  [[ ${1:-} =~ ^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$ ]]
}

# Re-check profile lines before they are embedded in the root-sourced config.
# Conversion already enforces this; write_config runs as root on possibly
# tampered files, so enforce it again at the sink.
valid_profile_token() {
  local token=${1:-} value
  [[ $token =~ ^[A-Za-z0-9_./,@:=+!~-]+$ ]] || return 1
  value=$token
  [[ $value == *=* ]] && value=${value#*=}
  value=${value#@}
  if [[ $token == */* ]]; then
    [[ $value != *..* && ( $value == "$FAKES_DIR"/* || $value == "$LISTS_DIR"/* ) ]] || return 1
  fi
}

# True when our table exists and a queue rule targets our queue. Capturing the
# output avoids SIGPIPE/pipefail false negatives on large nft sets.
nft_queue_loaded() {
  local rules
  # 0 = queue present, 1 = queue missing, 2 = cannot tell (no CAP_NET_ADMIN)
  rules=$(nft list table inet "$NFT_TABLE" 2>/dev/null) \
    || { [[ $(id -u) -eq 0 ]] && return 1; return 2; }
  grep -q "queue.*$NFQUEUE_NUM" <<< "$rules"
}

# merge_test_results FILE "name score"...
# Updates named entries, preserves all others, and replaces the file atomically.
merge_test_results() {
  local file=${1:?file required} entry name score tmp
  shift
  local -A merged=()
  if [[ -f $file ]]; then
    while read -r name score; do
      if [[ -n $name ]]; then
        merged[$name]=$score
      fi
    done < "$file"
  fi
  for entry in "$@"; do
    name=${entry%% *}
    score=${entry#* }
    merged[$name]=$score
  done
  tmp=$file.tmp
  : > "$tmp"
  for name in "${!merged[@]}"; do
    printf '%s %s\n' "$name" "${merged[$name]}" >> "$tmp"
  done
  mv "$tmp" "$file"
}

# Remove exact comma-separated port tokens from a port list.
remove_ports() {
  local list=$1 drop=$2 p d
  local -a drops=() ports=() out=()
  local -A skip=()
  IFS=, read -ra drops <<< "$drop"
  for d in "${drops[@]}"; do skip[$d]=1; done
  IFS=, read -ra ports <<< "$list"
  for p in "${ports[@]}"; do
    if [[ -z ${skip[$p]:-} ]]; then out+=("$p"); fi
  done
  local IFS=,
  printf '%s\n' "${out[*]}"
}

# Remove whole nfqws profile blocks for disabled features. Blocks are
# separated by --new; a block is identified by its first filter line.
#   games off: drop the 1024-65535 game profiles (Flowseal uses port 12
#              when the game filter is disabled; we omit them entirely)
#   voice off: drop Discord RTC UDP/TCP profiles so RTC passes untouched
profile_effective() {
  local file=$1 games=${2:-off} voice=${3:-on}
  awk -v games="$games" -v voice="$voice" '
    function emit(   first, keep) {
      if (block == "") return
      first = block
      sub(/\n.*/, "", first)
      keep = 1
      if (games != "on" && first == "--filter-tcp=1024-65535") keep = 0
      if (games != "on" && first == "--filter-udp=1024-65535") keep = 0
      if (voice != "on" && first == "--filter-udp=19294-19344,50000-50100") keep = 0
      if (voice != "on" && first == "--filter-tcp=2053,2083,2087,2096,8443") keep = 0
      if (keep) {
        if (count++) printf "--new\n"
        printf "%s", block
      }
      block = ""
    }
    /^--new$/ { emit(); next }
    { block = block $0 "\n" }
    END { emit() }
  ' "$file"
}

# Flowseal/Hypixel fix for Cloudflare Spectrum + ECH on TCP 25565. It must be
# the first nfqws profile: the game-range profile would otherwise claim 25565.
minecraft_profile() {
  cat <<EOF
--filter-tcp=25565
--ipset-exclude=$LISTS_DIR/ipset-exclude.txt
--ipset-exclude=$LISTS_DIR/ipset-exclude-user.txt
--dpi-desync-any-protocol=1
--dpi-desync-cutoff=n5
--dpi-desync=multisplit
--dpi-desync-split-seqovl=582
--dpi-desync-split-pos=1
--dpi-desync-split-seqovl-pattern=$FAKES_DIR/tls_clienthello_4pda_to.bin
EOF
}

build_opt() {
  local strategy=${1:?strategy required} games=${2:-off} voice=${3:-on} minecraft=${4:-off}
  local opt
  profile_exists "$strategy" || die "Unknown strategy: $strategy"
  opt=$(profile_effective "$PROFILES_DIR/$strategy.opt" "$games" "$voice")
  if [[ $minecraft == on ]]; then
    printf '%s\n--new\n%s\n' "$(minecraft_profile)" "$opt"
  else
    printf '%s\n' "$opt"
  fi
}

# Dry-run the exact filtered profile that will be written for a state.
validate_effective_config() {
  local strategy=${1:?} games=${2:-off} voice=${3:-on} minecraft=${4:-off} line
  local -a args=()
  while IFS= read -r line; do
    [[ -n $line ]] && args+=("$line")
  done < <(build_opt "$strategy" "$games" "$voice" "$minecraft")
  "$ENGINE_DIR/nfq/nfqws" --dry-run --qnum="$NFQUEUE_NUM" "${args[@]}" >/dev/null
}

# Regenerate the upstream config from config.default plus a minimal override
# block. Profile args are validated by lib/strategy.sh before they land here;
# the config is shell-sourced by the upstream init script.
write_config() {
  local strategy=${1:?strategy required} games=${2:-off} voice=${3:-$(current_voice)} minecraft=${4:-$(current_minecraft)}
  local profile=$PROFILES_DIR/$strategy
  local tcp udp opt line

  profile_exists "$strategy" || die "Unknown strategy: $strategy"
  [[ -f $profile.tcp && -f $profile.udp && -f $profile.opt ]] || die "Unknown strategy: $strategy"
  tcp=$(<"$profile.tcp")
  udp=$(<"$profile.udp")
  if [[ $games == on ]]; then
    tcp+=,$GAME_PORTS
    udp+=,$GAME_PORTS
  fi
  if [[ $voice == off ]]; then
    tcp=$(remove_ports "$tcp" "2053,2083,2087,2096,8443")
    udp=$(remove_ports "$udp" "19294-19344,50000-50100")
  fi
  if [[ $minecraft == on && $games != on ]]; then
    tcp+=,25565
  fi
  opt=$(build_opt "$strategy" "$games" "$voice" "$minecraft")

  valid_ports "$tcp" || die "Invalid TCP port list for strategy: $strategy"
  valid_ports "$udp" || die "Invalid UDP port list for strategy: $strategy"
  while IFS= read -r line; do
    if [[ -n $line ]]; then
      valid_profile_token "$line" || die "Unsafe profile line for strategy: $strategy: $line"
    fi
  done <<< "$opt"

  {
    cat "$ENGINE_DIR/config.default"
    cat <<EOF

# ---- zapret-arch generated overrides: edit via zapret-arch, not by hand ----
FWTYPE=nftables
MODE_FILTER=none
INIT_APPLY_FW=1
NFQWS_ENABLE=1
QNUM=$NFQUEUE_NUM
ZAPRET_NFT_TABLE=$NFT_TABLE
NFQWS_PORTS_TCP="$tcp"
NFQWS_PORTS_UDP="$udp"
NFQWS_OPT="
$opt
"
EOF
  } > "$CONFIG_FILE.tmp"
  mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
}
