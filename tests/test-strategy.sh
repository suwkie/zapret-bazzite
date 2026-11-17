#!/usr/bin/env bash
# Self-check for the .bat -> nfqws converter. Run: bash tests/test-strategy.sh
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export ZAPRET_HOME=$(mktemp -d)
trap 'rm -rf "$ZAPRET_HOME"' EXIT

source "$ROOT/lib/common.sh"
source "$ROOT/lib/strategy.sh"

mkdir -p "$ZAPRET_HOME/fakes" "$ZAPRET_HOME/lists"
printf 'fake' > "$ZAPRET_HOME/fakes/quic.bin"
printf 'fake' > "$ZAPRET_HOME/fakes/tls.bin"
printf 'fake' > "$ZAPRET_HOME/fakes/tls_clienthello_4pda_to.bin"
printf 'example.com\n' > "$ZAPRET_HOME/lists/list.txt"

assert_eq() {
  local label=$1 expected=$2 actual=$3
  [[ $actual == "$expected" ]] || {
    printf 'FAIL %s\n  expected: %q\n  actual:   %q\n' "$label" "$expected" "$actual" >&2
    exit 1
  }
  printf 'ok   %s\n' "$label"
}

cat > "$ZAPRET_HOME/test.bat" <<'BAT'
@echo off
start "zapret: %~n0" /min "%BIN%winws.exe" --wf-tcp=80,443,%GameFilterTCP% --wf-udp=443,%GameFilterUDP% ^
--filter-udp=443 --hostlist="%LISTS%list.txt" --dpi-desync=fake --dpi-desync-fake-quic="%BIN%quic.bin" --new ^
--filter-tcp=443 --dpi-desync=fake --dpi-desync-fake-tls=^! --dpi-desync-fake-tls="%BIN%tls.bin" --new ^
--filter-tcp=%GameFilterTCP% --dpi-desync=multisplit --dpi-desync-split-pos=1
BAT

out=$ZAPRET_HOME/out
convert_bat "$ZAPRET_HOME/test.bat" "$ZAPRET_HOME/fakes" "$ZAPRET_HOME/lists" "$out"

assert_eq "tcp ports exclude game range" "80,443" "$(<"$out.tcp")"
assert_eq "udp ports exclude game range" "443" "$(<"$out.udp")"
assert_eq "slugify" "general-fake-tls-auto-alt2" "$(slugify 'general (FAKE TLS AUTO ALT2).bat')"
grep -qx -- "--filter-tcp=$GAME_PORTS" "$out.opt" || { echo "FAIL game profile filter" >&2; exit 1; }
printf 'ok   game profile filter\n'
grep -qx -- "--dpi-desync-fake-tls=!" "$out.opt" || { echo "FAIL caret escape" >&2; exit 1; }
printf 'ok   caret escape\n'
grep -qx -- "--hostlist=$ZAPRET_HOME/lists/list.txt" "$out.opt" || { echo "FAIL list path" >&2; exit 1; }
printf 'ok   list path\n'
grep -qx -- "--dpi-desync-fake-quic=$ZAPRET_HOME/fakes/quic.bin" "$out.opt" || { echo "FAIL fake path" >&2; exit 1; }
printf 'ok   fake path\n'
! grep -qE '%|"|--wf-' "$out.opt" || { echo "FAIL leftovers in profile" >&2; exit 1; }
printf 'ok   no placeholders or winws flags\n'

# Duplicate slugs must skip one strategy, not abort the install.
mkdir -p "$ZAPRET_HOME/dupbats"
cp "$ZAPRET_HOME/test.bat" "$ZAPRET_HOME/dupbats/general-alt10.bat"
cp "$ZAPRET_HOME/test.bat" "$ZAPRET_HOME/dupbats/general (ALT10).bat"
build_profiles "$ZAPRET_HOME/dupbats" "$ZAPRET_HOME/fakes" "$ZAPRET_HOME/lists" "$ZAPRET_HOME/dupprofiles"
[[ -f "$ZAPRET_HOME/dupprofiles/general-alt10.opt" ]] || { echo "FAIL duplicate slug lost the strategy" >&2; exit 1; }
printf 'ok   duplicate slug skipped, install continues\n'

cat > "$ZAPRET_HOME/unsafe.bat" <<'BAT'
start "" "%BIN%winws.exe" --wf-tcp=443 --wf-udp=443 --dpi-desync=fake --dpi-desync-fake-tls=$(touch /tmp/pwned)
BAT
rm -f /tmp/pwned
if convert_bat "$ZAPRET_HOME/unsafe.bat" "$ZAPRET_HOME/fakes" "$ZAPRET_HOME/lists" "$ZAPRET_HOME/unsafe"; then
  echo "FAIL unsafe token accepted" >&2
  exit 1
fi
[[ ! -e /tmp/pwned ]] || { echo "FAIL unsafe token executed" >&2; exit 1; }
printf 'ok   unsafe token rejected and not executed\n'

cat > "$ZAPRET_HOME/escape.bat" <<'BAT'
start "" "%BIN%winws.exe" --wf-tcp=443 --wf-udp=443 --dpi-desync=fake --dpi-desync-fake-tls=/etc/passwd
BAT
if convert_bat "$ZAPRET_HOME/escape.bat" "$ZAPRET_HOME/fakes" "$ZAPRET_HOME/lists" "$ZAPRET_HOME/escape"; then
  echo "FAIL path escape accepted" >&2
  exit 1
fi
printf 'ok   path escape rejected\n'

cat > "$ZAPRET_HOME/escape2.bat" <<'BAT'
start "" "%BIN%winws.exe" --wf-tcp=443 --wf-udp=443 --dpi-desync=fake --dpi-desync-fake-tls /etc/passwd
BAT
if convert_bat "$ZAPRET_HOME/escape2.bat" "$ZAPRET_HOME/fakes" "$ZAPRET_HOME/lists" "$ZAPRET_HOME/escape2"; then
  echo "FAIL space-separated path escape accepted" >&2
  exit 1
fi
printf 'ok   space-separated path escape rejected\n'

cat > "$ZAPRET_HOME/space.bat" <<'BAT'
start "" "%BIN%winws.exe" --wf-tcp=443 --wf-udp=443 --dpi-desync=fake --dpi-desync-fake-tls "%BIN%tls.bin"
BAT
convert_bat "$ZAPRET_HOME/space.bat" "$ZAPRET_HOME/fakes" "$ZAPRET_HOME/lists" "$ZAPRET_HOME/space"
grep -qx -- "--dpi-desync-fake-tls" "$ZAPRET_HOME/space.opt" \
  && grep -qx -- "$ZAPRET_HOME/fakes/tls.bin" "$ZAPRET_HOME/space.opt" || {
  echo "FAIL space-separated file form" >&2
  exit 1
}
printf 'ok   space-separated file form\n'

# Config generation: game range is appended to firewall ports, not duplicated.
mkdir -p "$ZAPRET_HOME/engine" "$ZAPRET_HOME/profiles"
cat > "$ZAPRET_HOME/engine/config.default" <<'EOF'
NFQWS_ENABLE=0
NFQWS_PORTS_TCP=80
NFQWS_PORTS_UDP=443
MODE_FILTER=none
EOF
cp "$out.opt" "$out.tcp" "$out.udp" "$ZAPRET_HOME/profiles/"
mv "$ZAPRET_HOME/profiles/out.opt" "$ZAPRET_HOME/profiles/general.opt"
mv "$ZAPRET_HOME/profiles/out.tcp" "$ZAPRET_HOME/profiles/general.tcp"
mv "$ZAPRET_HOME/profiles/out.udp" "$ZAPRET_HOME/profiles/general.udp"

profile_exists general || { echo "FAIL valid profile rejected" >&2; exit 1; }
: > "$ZAPRET_HOME/escape.opt"
: > "$ZAPRET_HOME/profiles/General.opt"
! profile_exists '../escape' || { echo "FAIL traversal name accepted" >&2; exit 1; }
! profile_exists 'General' || { echo "FAIL uppercase name accepted" >&2; exit 1; }
printf 'ok   profile name validation\n'

nft() { printf 'table inet zapret_arch { chain postnat { queue num 201 bypass } }\n'; }
nft_queue_loaded || { echo "FAIL queue 201 not matched" >&2; exit 1; }
nft() { printf 'table inet zapret_arch { chain postnat { } }\n'; }
! nft_queue_loaded || { echo "FAIL missing queue matched" >&2; exit 1; }
unset -f nft
grep -Fq 'queue.*@NFQUEUE_NUM@' "$ROOT/systemd/zapret-arch.service" \
  || { echo "FAIL unit queue regex drifted" >&2; exit 1; }
printf 'ok   queue number match\n'

cp "$out.opt" "$ZAPRET_HOME/profiles/bad.opt"
printf '443\n' > "$ZAPRET_HOME/profiles/bad.udp"
printf 'x";id>/tmp/pwned\n' > "$ZAPRET_HOME/profiles/bad.tcp"
if ( write_config bad off on off ) 2> "$ZAPRET_HOME/bad.err"; then
  echo "FAIL invalid tcp list accepted" >&2; exit 1
fi
grep -q 'Invalid TCP port list' "$ZAPRET_HOME/bad.err" \
  || { echo "FAIL invalid tcp list failed for the wrong reason" >&2; exit 1; }
printf 'ok   invalid port list rejected\n'

cp "$out.opt" "$ZAPRET_HOME/profiles/badopt.opt"
printf '80,443\n' > "$ZAPRET_HOME/profiles/badopt.tcp"
printf '443\n' > "$ZAPRET_HOME/profiles/badopt.udp"
printf -- '--new\n--filter-tcp=443\n--dpi-desync=$(id)\n' >> "$ZAPRET_HOME/profiles/badopt.opt"
if ( write_config badopt off on off ) 2> "$ZAPRET_HOME/badopt.err"; then
  echo "FAIL unsafe profile token accepted" >&2; exit 1
fi
grep -q 'Unsafe profile line' "$ZAPRET_HOME/badopt.err" \
  || { echo "FAIL unsafe token failed for the wrong reason" >&2; exit 1; }
printf 'ok   unsafe profile token rejected\n'

write_config general on
(
  source "$ZAPRET_HOME/engine/config"
  assert_eq "config tcp with games" "80,443,1024-65535" "$NFQWS_PORTS_TCP"
  assert_eq "config udp with games" "443,1024-65535" "$NFQWS_PORTS_UDP"
  assert_eq "config enables nfqws" "1" "$NFQWS_ENABLE"
  assert_eq "config queue number" "201" "$QNUM"
  assert_eq "config nft table" "zapret_arch" "$ZAPRET_NFT_TABLE"
  grep -qx -- "--filter-tcp=1024-65535" <<<"$NFQWS_OPT" || {
    echo "FAIL NFQWS_OPT missing profile" >&2; exit 1;
  }
  printf 'ok   config NFQWS_OPT\n'
)
write_config general off
(
  source "$ZAPRET_HOME/engine/config"
  assert_eq "config tcp without games" "80,443" "$NFQWS_PORTS_TCP"
  [[ $NFQWS_OPT != *"--filter-tcp=1024-65535"* ]] || {
    echo "FAIL game profile survived games off" >&2; exit 1;
  }
  printf 'ok   games off drops game profile\n'
)
printf 'ok   config generation\n'

write_config general off on on
(
  source "$ZAPRET_HOME/engine/config"
  assert_eq "tcp with minecraft" "80,443,25565" "$NFQWS_PORTS_TCP"
  assert_eq "minecraft profile is first" "--filter-tcp=25565" "$(grep -m1 '^--' <<<"$NFQWS_OPT")"
  grep -qx -- "--dpi-desync-split-seqovl=582" <<<"$NFQWS_OPT" || {
    echo "FAIL minecraft seqovl missing" >&2; exit 1;
  }
  grep -q -- "$ZAPRET_HOME/fakes/tls_clienthello_4pda_to.bin" <<<"$NFQWS_OPT" || {
    echo "FAIL minecraft fake pattern missing" >&2; exit 1;
  }
  [[ $(grep -c '^--filter-tcp=25565$' <<<"$NFQWS_OPT") -eq 1 ]] || {
    echo "FAIL duplicate minecraft profile" >&2; exit 1;
  }
  awk '/^--filter-tcp=25565$/{mc=1;next} mc && /^--new$/{n++;mc=0} END{exit !(n==1)}' <<<"$NFQWS_OPT" || {
    echo "FAIL minecraft profile not separated by --new" >&2; exit 1;
  }
  printf 'ok   minecraft profile\n'
)
write_config general on on on
(
  source "$ZAPRET_HOME/engine/config"
  assert_eq "games cover minecraft port" "80,443,1024-65535" "$NFQWS_PORTS_TCP"
  assert_eq "minecraft stays first with games" "--filter-tcp=25565" "$(grep -m1 '^--' <<<"$NFQWS_OPT")"
  printf 'ok   minecraft with games\n'
)
write_config general off on off
(
  source "$ZAPRET_HOME/engine/config"
  assert_eq "tcp without minecraft" "80,443" "$NFQWS_PORTS_TCP"
  [[ $NFQWS_OPT != *"--filter-tcp=25565"* ]] || {
    echo "FAIL minecraft profile survived minecraft off" >&2; exit 1;
  }
  printf 'ok   minecraft off removes profile\n'
)
set_minecraft on
assert_eq "minecraft state on" "on" "$(current_minecraft)"
set_minecraft off
assert_eq "minecraft state off" "off" "$(current_minecraft)"

assert_eq "remove UDP RTC ports" "443" \
  "$(remove_ports '443,19294-19344,50000-50100' '19294-19344,50000-50100')"
assert_eq "remove TCP media ports" "80,443" \
  "$(remove_ports '80,443,2053,2083,2087,2096,8443' '2053,2083,2087,2096,8443')"
printf 'ok   port removal\n'

rtc=$ZAPRET_HOME/rtc.opt
cat > "$rtc" <<'EOF'
--filter-udp=443
--dpi-desync=fake
--new
--filter-udp=19294-19344,50000-50100
--filter-l7=discord,stun
--dpi-desync=fake
--new
--filter-tcp=1024-65535
--dpi-desync=multisplit
EOF
filtered=$(profile_effective "$rtc" off off)
[[ $filtered == *"--filter-udp=443"* && $filtered != *19294* && $filtered != *1024-65535* ]] || {
  echo "FAIL voice/games profile filtering" >&2; exit 1;
}
printf 'ok   voice/games profile filtering\n'
full=$(profile_effective "$rtc" on on)
[[ $full == *19294* && $full == *1024-65535* ]] || {
  echo "FAIL profile filtering kept disabled blocks" >&2; exit 1;
}
printf 'ok   profile filtering keeps enabled blocks\n'

results=$ZAPRET_HOME/test-results
printf 'general 4/4\nalt 1/2\n' > "$results"
merge_test_results "$results" 'general 2/2' 'new FAIL'
grep -qx 'general 2/2' "$results" || { echo "FAIL merge update" >&2; exit 1; }
grep -qx 'alt 1/2' "$results" || { echo "FAIL merge preserve" >&2; exit 1; }
grep -qx 'new FAIL' "$results" || { echo "FAIL merge add" >&2; exit 1; }
[[ ! -e $results.tmp ]] || { echo "FAIL merge temp left behind" >&2; exit 1; }
printf 'ok   test result merge\n'

# Mojang host pin: off removes only marked lines, on rejects an unreachable IP.
hosts_fixture=$(mktemp)
printf '127.0.0.1 localhost\n150.171.110.114\tpiston-meta.mojang.com\t# minecraft-hosts-pin\n' > "$hosts_fixture"
HOSTS_FILE=$hosts_fixture "$ROOT/extras/minecraft-hosts.sh" off >/dev/null
[[ $(wc -l < "$hosts_fixture") -eq 1 ]] || { echo "FAIL host unpin" >&2; exit 1; }
HOSTS_FILE=$hosts_fixture "$ROOT/extras/minecraft-hosts.sh" on 192.0.2.1 >/dev/null 2>&1 \
  && { echo "FAIL unreachable pin accepted" >&2; exit 1; }
grep -q minecraft-hosts-pin "$hosts_fixture" && { echo "FAIL pin leaked" >&2; exit 1; }
printf 'ok   mojang host pin\n'

# Roblox pin: its own marker block, and `off` leaves the other group alone.
roblox_fixture=$(mktemp)
printf '127.0.0.1 localhost\n150.171.110.114\ttextures.minecraft.net\t# minecraft-hosts-pin\n' > "$roblox_fixture"
CANDIDATES=192.0.2.9 HOSTS_FILE=$roblox_fixture "$ROOT/extras/hosts-pin.sh" roblox on >/dev/null 2>&1 \
  && { echo "FAIL roblox pin accepted an unreachable address" >&2; exit 1; }
HOSTS_FILE=$roblox_fixture "$ROOT/extras/hosts-pin.sh" roblox on 192.0.2.1 >/dev/null 2>&1 \
  && { echo "FAIL roblox unreachable pin accepted" >&2; exit 1; }
grep -q roblox-hosts-pin "$roblox_fixture" && { echo "FAIL roblox pin leaked" >&2; exit 1; }
grep -q minecraft-hosts-pin "$roblox_fixture" || { echo "FAIL foreign block removed" >&2; exit 1; }
HOSTS_FILE=$roblox_fixture "$ROOT/extras/hosts-pin.sh" roblox off >/dev/null
grep -q minecraft-hosts-pin "$roblox_fixture" || { echo "FAIL minecraft block lost" >&2; exit 1; }
"$ROOT/extras/hosts-pin.sh" bogus on >/dev/null 2>&1 && { echo "FAIL unknown group accepted" >&2; exit 1; }
rm -f "$roblox_fixture"
printf 'ok   roblox host pin\n'

echo "All converter tests passed."
