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

RELEASES="https://github.com/aggnostos/seedex-agent/releases"

fetch_release() {
	local base tmp
	if [ -n "${SEEDEX_VERSION:-}" ]; then
		base="$RELEASES/download/v${SEEDEX_VERSION}"
	else
		base="$RELEASES/latest/download"
	fi
	command -v wget >/dev/null 2>&1 || die "wget is required to download seedex-agent"
	tmp=$(mktemp -d)
	log "downloading seedex-agent${SEEDEX_VERSION:+ v$SEEDEX_VERSION}"
	if ! wget -q -O "$tmp/seedex-agent.tar.gz" "$base/seedex-agent.tar.gz" ||
		! wget -q -O "$tmp/checksums.txt" "$base/checksums.txt"; then
		die "cannot download seedex-agent from $base"
	fi
	(cd "$tmp" && grep ' seedex-agent.tar.gz$' checksums.txt | sha256sum -c --status) ||
		die "seedex-agent.tar.gz does not match the published checksum"
	tar -xzf "$tmp/seedex-agent.tar.gz" -C "$tmp"
	SRC="$tmp"
	echo "  $(cat "$SRC/version")"
}

[ -f "$SRC/sdx" ] && [ -d "$SRC/lib" ] || fetch_release

export SEEDEX_BUILD_DIR="$SRC/build"

SVC="${1:-}"
case "$SVC" in
"" | vpn | proxy | link | files) ;;
*) die "unknown target: $SVC (vpn, proxy, link, or files to skip provisioning)" ;;
esac

for f in sdx version lib/common.sh lib/vpn.sh lib/proxy.sh lib/link.sh; do
	[ -f "$SRC/$f" ] || die "$f not found next to install.sh"
done

log "installing files"
install -d -m 0755 "$LIBDIR"
for f in common.sh vpn.sh proxy.sh link.sh; do
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
	[ -x /usr/local/bin/seedex-link ] || provision link
	for svc in vpn proxy link; do
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
case "$SVC" in
"" | vpn) provision vpn ;;
esac
case "$SVC" in
"" | proxy) provision proxy ;;
esac
case "$SVC" in
"" | link) provision link ;;
esac

log "done — seedex $("$BINDIR/sdx" version | awk '{print $2}') installed"
cat <<'EOF'

Nothing was started — the services are enabled but not running. Bring them up
when convenient:

  sdx start

Then:

  sdx                                 # status
  sdx link add router                 # pair a router: prints the command to run on it
  sdx export -o <dir>                 # or hand the native configs over yourself
EOF
