#!/usr/bin/env bash
# Convert Flowseal's Windows winws strategies into nfqws profiles.
# A profile is three files: .tcp and .udp hold firewall ports, .opt holds
# one nfqws argument per line. Downloaded .bat content is never executed.

# convert_bat BAT FAKES_DIR LISTS_DIR OUT_BASE
convert_bat() {
  local bat=${1:?} fakes=${2:?} lists=${3:?} out=${4:?}
  local joined tcp='' udp='' token

  [[ $fakes == */ ]] || fakes+=/
  [[ $lists == */ ]] || lists+=/

  # Join cmd.exe continuation lines, keep only the winws command.
  joined=$(tr -d '\r' < "$bat" \
    | sed -e ':a' -e '/\^[[:space:]]*$/N; s/\^[[:space:]]*\n/ /; ta' \
    | grep -m1 -i 'winws\.exe' \
    | sed -E 's/.*winws\.exe"?[[:space:]]*//') || return 1
  [[ -n $joined ]] || return 1
  joined=${joined//^!/!}   # cmd caret escape for the literal "!" fake-tls value
  read -ra tokens <<< "$joined"

  : > "$out.opt"
  for token in "${tokens[@]}"; do
    token=${token//\"/}
    case $token in
      --wf-tcp=*)
        tcp=${token#--wf-tcp=}
        tcp=${tcp//,%GameFilterTCP%/}
        tcp=${tcp//%GameFilterTCP%,/}
        tcp=${tcp//%GameFilterTCP%/}
        tcp=${tcp%,}
        ;;
      --wf-udp=*)
        udp=${token#--wf-udp=}
        udp=${udp//,%GameFilterUDP%/}
        udp=${udp//%GameFilterUDP%,/}
        udp=${udp//%GameFilterUDP%/}
        udp=${udp%,}
        ;;
      *)
        token=${token//%BIN%/$fakes}
        token=${token//%LISTS%/$lists}
        token=${token//%GameFilterTCP%/$GAME_PORTS}
        token=${token//%GameFilterUDP%/$GAME_PORTS}
        # File-valued options may only read the installed fake payloads or
        # lists. This covers both "--opt=/path" and the space-separated
        # "--opt /path" form. The config is sourced as root and nfqws opens
        # these files before dropping privileges.
        local value=$token
        [[ $value == *=* ]] && value=${value#*=}
        value=${value#@}
        if [[ $token == */* ]]; then
          if [[ $value == *..* || ( $value != "${fakes}"* && $value != "${lists}"* ) ]]; then
            warn "File path outside fakes/lists in $(basename "$bat"): $token"
            return 2
          fi
        fi
        # Trust boundary: the config file is shell-sourced as root later.
        # Reject anything that could be interpreted as shell syntax.
        if [[ ! $token =~ ^[A-Za-z0-9_./,@:=+!~-]+$ ]]; then
          warn "Unsafe token in $(basename "$bat"): $token"
          return 2
        fi
        printf '%s\n' "$token" >> "$out.opt"
        ;;
    esac
  done

  [[ -n $tcp && -n $udp ]] || return 3
  [[ $tcp =~ ^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$ ]] || return 4
  [[ $udp =~ ^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$ ]] || return 4
  printf '%s\n' "$tcp" > "$out.tcp"
  printf '%s\n' "$udp" > "$out.udp"
}

# build_profiles BATS_DIR FAKES_DIR LISTS_DIR OUT_DIR
build_profiles() {
  local bats=${1:?} fakes=${2:?} lists=${3:?} out=${4:?}
  local bat slug count=0

  [[ $out != / && -n $out ]] || die "Refusing to clear profiles directory: $out"
  rm -rf "$out"
  mkdir -p "$out"
  for bat in "$bats"/general*.bat; do
    [[ -f $bat ]] || continue
    slug=$(slugify "$(basename "$bat")")
    if [[ -z $slug ]]; then
      warn "Empty strategy name: $(basename "$bat")"
      continue
    fi
    if [[ -e $out/$slug.opt ]]; then
      warn "Duplicate strategy name: $slug (skipping $(basename "$bat"))"
      continue
    fi
    if convert_bat "$bat" "$fakes" "$lists" "$out/$slug"; then
      if [[ -f $out/$slug.tcp && -f $out/$slug.udp ]]; then
        count=$((count + 1))
      else
        rm -f "$out/$slug".*
        warn "Incomplete strategy: $(basename "$bat")"
      fi
    else
      rm -f "$out/$slug".*
      warn "Skipping strategy: $(basename "$bat")"
    fi
  done
  (( count > 0 )) || die "No strategies converted from $bats"
  log "Converted $count strategies"
}

# validate_profiles PROFILES_DIR NFQWS
validate_profiles() {
  local dir=${1:?} nfqws=${2:?} opt count=0
  local -a args

  for opt in "$dir"/*.opt; do
    [[ -f $opt ]] || continue
    mapfile -t args < "$opt"
    if ! "$nfqws" --dry-run --qnum="$NFQUEUE_NUM" "${args[@]}" >/dev/null 2>"$opt.err"; then
      warn "Invalid profile: $(basename "$opt" .opt)"
      cat "$opt.err" >&2
      return 1
    fi
    rm -f "$opt.err"
    count=$((count + 1))
  done
  log "Validated $count profiles with nfqws"
}
