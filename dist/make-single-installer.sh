#!/usr/bin/env bash
# Build a single-file installer: the whole tree (minus build output) embedded
# as a base64 tar payload in one script.
#
#   ./dist/make-single-installer.sh [-o OUT] [TREE]
#
# TREE defaults to the repository root. The payload is reproducible enough for
# a release asset: the same commit gives the same bytes once tar sorts names.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/.." && pwd)
out=$here/install-zapret-bazzite.sh
tree=$root

while getopts ':o:h' opt; do
  case $opt in
    o) out=$OPTARG ;;
    h) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option" >&2; exit 2 ;;
  esac
done
shift $((OPTIND - 1))
[[ $# -gt 0 ]] && tree=$1

[[ -f $tree/install.sh ]] || { echo "not a zapret tree: $tree" >&2; exit 1; }

payload=$(mktemp)
trap 'rm -f "$payload"' EXIT
# Sorted names, fixed owner, no build output — the payload must not depend on
# who runs the build.
tar --create --directory "$tree" \
    --exclude=./gui/target --exclude=./.git --exclude=./dist/install-zapret-bazzite.sh \
    --owner=0 --group=0 --numeric-owner --sort=name \
    . | gzip -9n > "$payload"

{
  cat <<'HEADER'
#!/usr/bin/env bash
# zapret-bazzite — single-file installer.
#
# The whole project is embedded below as a base64 tar payload, so this script
# needs no clone and no second download. Everything the installer does is the
# same as running install.sh from the repository.
#
#   sudo bash install-zapret-bazzite.sh            install under /usr/local
#   sudo bash install-zapret-bazzite.sh --no-gui   skip the desktop GUI
#   bash install-zapret-bazzite.sh --prefix DIR --no-systemd   staging, no root
#   sudo bash install-zapret-bazzite.sh --start    start the service after install
#
# Built from the repository at the tag in the release notes; regenerating it
# from the same commit produces the same bytes.
set -euo pipefail

if [[ ${1:-} == --version ]]; then
  echo "zapret-bazzite single-file installer"
  exit 0
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/zapret-install.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

payload_line=$(grep -an '^__ZAPRET_PAYLOAD__$' "$0" | head -1 | cut -d: -f1)
[[ -n $payload_line ]] || { echo "corrupt installer: payload marker missing" >&2; exit 1; }
tail -n +"$((payload_line + 1))" "$0" | base64 -d | tar -xz -C "$tmp"

# The tarball holds the tree at its top level.
tree=$tmp
[[ -f $tree/install.sh ]] || tree=$(find "$tmp" -maxdepth 1 -mindepth 1 -type d | head -1)
[[ -f $tree/install.sh ]] || { echo "corrupt installer: install.sh missing" >&2; exit 1; }

# update must re-run the installed copy, not this script's temp directory
export ZAPRET_SOURCE_DIR=${ZAPRET_SOURCE_DIR:-self}
exec "$tree/install.sh" "$@"
__ZAPRET_PAYLOAD__
HEADER
  base64 -w 76 "$payload"
} > "$out"

chmod 755 "$out"
printf 'wrote %s (%s, payload %s)\n' "$out" \
  "$(du -h "$out" | cut -f1)" "$(du -h "$payload" | cut -f1)"
