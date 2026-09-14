#!/bin/bash

set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
BINDIR="/usr/local/bin"
LIBDIR="/usr/local/lib/seedex"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() {
	printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2
	exit 1
}

[ "$(id -u)" -eq 0 ] || die "must be run as root"

SVC="${1:-}"
case "$SVC" in
"" | vpn | proxy | files) ;;
*) die "unknown target: $SVC (vpn, proxy, or files to skip provisioning)" ;;
esac

for f in sdx version lib/common.sh lib/vpn.sh lib/proxy.sh; do
	[ -f "$SRC/$f" ] || die "$f not found next to install.sh"
done

log "installing files"
install -d -m 0755 "$LIBDIR"
for f in common.sh vpn.sh proxy.sh; do
	install -m 0644 "$SRC/lib/$f" "$LIBDIR/$f"
	echo "  $LIBDIR/$f"
done
install -m 0644 "$SRC/version" "$LIBDIR/version"
install -m 0755 "$SRC/sdx" "$BINDIR/sdx"
echo "  $BINDIR/sdx"

provision() {
	log "provisioning $1"
	(
		# shellcheck source=lib/common.sh
		. "$LIBDIR/common.sh"
		# shellcheck source=lib/vpn.sh
		. "$LIBDIR/${1}.sh"
		svc_provision
	)
	echo
}

echo
if [ "$SVC" = files ]; then
	for svc in vpn proxy; do
		(
			# shellcheck source=lib/common.sh
			. "$LIBDIR/common.sh"
			# shellcheck source=lib/vpn.sh
			. "$LIBDIR/${svc}.sh"
			svc_upgrade
		)
	done
	log "done — seedex $("$BINDIR/sdx" version | awk '{print $2}') files updated"
	exit 0
fi
[ -n "$SVC" ] && [ "$SVC" != vpn ] || provision vpn
[ -n "$SVC" ] && [ "$SVC" != proxy ] || provision proxy

log "done — seedex $("$BINDIR/sdx" version | awk '{print $2}') installed"
cat <<'EOF'

Nothing was started — the services are enabled but not running. Bring them up
when convenient:

  sdx start

Then:

  sdx
  sdx export -o /tmp/seedex           # native configs to import on the Box
EOF
