#!/bin/sh
# Pin hosts that the local resolver answers wrongly or that resolve to an
# address this ISP drops. Each group owns one marked block in /etc/hosts:
# `on` rewrites it, `off` removes only it, `check` probes without touching.
# Usage: hosts-pin.sh <minecraft|roblox> on|off|check [IP]
set -eu

HOSTS_FILE=${HOSTS_FILE:-/etc/hosts}
group=${1:-}
mode=${2:-on}
want_ip=${3:-}

case $group in
  minecraft)
    # The ISP drops TCP 443 to 150.171.109.53, the address these names mostly
    # resolve to; siblings answer and Front Door routes by SNI/Host.
    MARK='# minecraft-hosts-pin'
    HOSTS='piston-meta.mojang.com piston-data.mojang.com resources.download.minecraft.net libraries.minecraft.net launchermeta.mojang.com sessionserver.mojang.com textures.minecraft.net api.minecraftservices.com api.mojang.com'
    CANDIDATES=${CANDIDATES:-'150.171.110.114 150.171.110.118 150.171.109.197 150.171.109.198'}
    ;;
  roblox)
    # The resolver returns tr.rbxcdn.com's CNAME and withholds the A records of
    # trns1.rbxcdn.com, so icons never resolve. Every CloudFront edge serves the
    # name; the list is verified now and rotates over time — refresh with
    # `dig +short A tr.rbxcdn.com @9.9.9.9` and pass the address explicitly.
    MARK='# roblox-hosts-pin'
    HOSTS='tr.rbxcdn.com'
    CANDIDATES=${CANDIDATES:-'3.174.2.70 3.174.2.108 143.204.238.81 2.21.64.175'}
    ;;
  *)
    echo "Usage: $0 <minecraft|roblox> on|off|check [IP]" >&2
    exit 2
    ;;
esac

[ -f "$HOSTS_FILE" ] || { echo "missing $HOSTS_FILE" >&2; exit 1; }

reachable() {
  timeout 3 sh -c "exec 3<>/dev/tcp/$1/443" 2>/dev/null
}

case $mode in
  check)
    for host in $HOSTS; do
      printf '%-36s ' "$host"
      curl -4 -sS -m 8 -o /dev/null -w '%{http_code}\n' "https://$host/" 2>/dev/null \
        || echo FAIL
    done
    exit 0
    ;;
  on|off) ;;
  *) echo "Usage: $0 <minecraft|roblox> on|off|check [IP]" >&2; exit 2 ;;
esac

[ "$HOSTS_FILE" = /etc/hosts ] && [ "$(id -u)" -ne 0 ] \
  && { echo "run as root" >&2; exit 1; }

# Write through `cat` to keep the inode (bind mounts), but keep a copy first:
# an interrupted write would otherwise leave /etc/hosts truncated.
replace_hosts() {
  backup=$HOSTS_FILE.zapret-bak
  cp -p "$HOSTS_FILE" "$backup" || exit 1
  if ! cat "$1" > "$HOSTS_FILE"; then
    cp -p "$backup" "$HOSTS_FILE"
    rm -f "$backup" "$1"
    echo "write failed; $HOSTS_FILE restored" >&2
    exit 1
  fi
  rm -f "$backup"
}

strip_block() {
  tmp=$(mktemp) || exit 1
  grep -vF "$MARK" "$HOSTS_FILE" > "$tmp" || true
  replace_hosts "$tmp"
  rm -f "$tmp"
}

case $mode in
  off)
    strip_block
    echo "unpinned $HOSTS_FILE ($group)"
    exit 0
    ;;
esac

ip=$want_ip
if [ -z "$ip" ]; then
  for candidate in $CANDIDATES; do
    if reachable "$candidate"; then ip=$candidate; break; fi
  done
fi
[ -n "$ip" ] || { echo "no reachable address in: $CANDIDATES" >&2; exit 1; }
reachable "$ip" || { echo "$ip:443 unreachable; pass another address" >&2; exit 1; }

tmp=$(mktemp) || exit 1
grep -vF "$MARK" "$HOSTS_FILE" > "$tmp" || true
for host in $HOSTS; do
  printf '%s\t%s\t%s\n' "$ip" "$host" "$MARK" >> "$tmp"
done
replace_hosts "$tmp"
rm -f "$tmp"

echo "pinned $(( $(printf '%s\n' $HOSTS | wc -l) )) $group hosts to $ip"
