# shellcheck shell=bash

SVC_ACTIONS="start stop restart add remove rotate"

LINK_DIR="/etc/seedex/link"
LINK_ROUTERS="$LINK_DIR/routers"
LINK_CERT="$LINK_DIR/cert.pem"
LINK_KEY="$LINK_DIR/key.pem"
LINK_PORT="${SEEDEX_LINK_PORT:-8447}"

BINARY="/usr/local/bin/seedex-link"
RELEASES="https://github.com/aggnostos/seedex-agent/releases/download"

SERVICE="seedex-link"
SERVICE_FILE="/etc/systemd/system/${SERVICE}.service"

_arch() {
	case "$(uname -m)" in
	x86_64) echo amd64 ;;
	aarch64) echo arm64 ;;
	*) die "unsupported architecture: $(uname -m)" ;;
	esac
}

_binary_version() {
	[ -x "$BINARY" ] && "$BINARY" -version 2>/dev/null || true
}

_install_binary() {
	need_root
	local arch name local_build tmp
	arch=$(_arch)
	name="seedex-link_linux_${arch}"
	local_build="${SEEDEX_BUILD_DIR:-}/$name"

	if [ "$(_binary_version)" = "$SEEDEX_VERSION" ] && [ ! -f "$local_build" ]; then
		echo "seedex-link v${SEEDEX_VERSION} already installed"
		return
	fi

	if [ -f "$local_build" ]; then
		install -m 0755 "$local_build" "$BINARY.new"
	else
		echo "Downloading seedex-link v${SEEDEX_VERSION} (${arch})..."
		tmp=$(mktemp -d)
		if ! wget -q -O "$tmp/$name" "$RELEASES/v${SEEDEX_VERSION}/$name" ||
			! wget -q -O "$tmp/checksums.txt" "$RELEASES/v${SEEDEX_VERSION}/checksums.txt"; then
			rm -rf "$tmp"
			die "cannot download seedex-link v${SEEDEX_VERSION} — check outbound access to github.com"
		fi
		(cd "$tmp" && grep " $name\$" checksums.txt | sha256sum -c --status) || {
			rm -rf "$tmp"
			die "seedex-link does not match the published checksum"
		}
		install -m 0755 "$tmp/$name" "$BINARY.new"
		rm -rf "$tmp"
	fi
	mv -f "$BINARY.new" "$BINARY"
	echo "Installed: seedex-link $(_binary_version)"
}

_gen_cert() {
	[ -f "$LINK_CERT" ] && [ -f "$LINK_KEY" ] && return 0
	openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -pkeyopt ec_param_enc:named_curve \
		-keyout "$LINK_KEY" -out "$LINK_CERT" \
		-days 3650 -nodes -subj "/CN=seedex-link" 2>/dev/null ||
		die "cannot generate the API certificate"
	chmod 600 "$LINK_KEY"
	echo "  Certificate generated"
}

_fingerprint() {
	[ -f "$LINK_CERT" ] || return 1
	printf 'sha256//%s\n' "$(openssl x509 -in "$LINK_CERT" -pubkey -noout |
		openssl pkey -pubin -outform der 2>/dev/null |
		openssl dgst -sha256 -binary | base64)"
}

_install_service() {
	cat >"$SERVICE_FILE" <<EOU
[Unit]
Description=Seedex link API
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BINARY -listen :$LINK_PORT -dir $LINK_DIR
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOU
	systemctl daemon-reload
	systemctl enable "$SERVICE" >/dev/null 2>&1
}

_ensure_service() {
	[ -f "$SERVICE_FILE" ] || _install_service
}

_routers() {
	local f
	for f in "$LINK_ROUTERS"/*.token; do
		[ -f "$f" ] || continue
		f="${f##*/}"
		echo "${f%.token}"
	done
}

_check_name() {
	case "$1" in
	"" | *[!A-Za-z0-9._-]* | -*)
		die "invalid router name '$1' — use letters, digits, dot, dash or underscore"
		;;
	esac
}

svc_provision() {
	need_root
	need_cmd openssl

	echo "[1/4] Checking seedex-link..."
	_install_binary

	echo "[2/4] Setting up directories and certificate..."
	mkdir -p "$LINK_ROUTERS"
	chmod 700 "$LINK_DIR" "$LINK_ROUTERS"
	_gen_cert
	echo "  $LINK_DIR"

	echo "[3/4] Installing service..."
	_install_service
	echo "  Service installed and enabled (starts on boot)"

	echo "[4/4] Configuring firewall..."
	firewall_allow "${LINK_PORT}/tcp:seedex-link"
	echo "  Firewall configured"

	echo
	[ -n "$(_routers)" ] || echo "No routers yet — pair one with: sdx link add <router>"
}

svc_upgrade() {
	[ -x "$BINARY" ] || return 0
	local local_build
	local_build="${SEEDEX_BUILD_DIR:-}/seedex-link_linux_$(_arch)"
	[ "$(_binary_version)" != "$SEEDEX_VERSION" ] || [ -f "$local_build" ] || return 0
	_install_binary
	systemctl is-active --quiet "$SERVICE" || return 0
	systemctl restart "$SERVICE"
	echo "seedex-link restarted on v$(_binary_version)"
}

svc_start() {
	need_root
	_ensure_service
	if systemctl is-active --quiet "$SERVICE"; then
		echo "Already running"
		return
	fi
	systemctl start "$SERVICE"
	echo "Started"
}

svc_stop() {
	need_root
	_ensure_service
	if ! systemctl is-active --quiet "$SERVICE"; then
		echo "Not running"
		return
	fi
	systemctl stop "$SERVICE"
	echo "Stopped"
}

svc_restart() {
	need_root
	_ensure_service
	systemctl restart "$SERVICE"
	echo "Restarted"
}

svc_status() {
	local up=0 r n=0
	systemctl is-active --quiet "$SERVICE" && up=1
	status_header "Link" "$up"
	field "Port:" "${LINK_PORT}/tcp"
	if [ -f "$LINK_CERT" ]; then
		field "Fingerprint:" "$(_fingerprint)"
	else
		field "Certificate:" "missing (run: ./install.sh link)"
	fi
	for r in $(_routers); do
		[ "$n" -gt 0 ] || echo "  Routers:"
		printf '    %s\n' "$r"
		n=$((n + 1))
	done
	[ "$n" -gt 0 ] || field "Routers:" "none — pair one with: sdx link add <router>"
}

svc_add() {
	need_root
	local router="${1:-}" token
	[ -n "$router" ] || usage "sdx link add <router>"
	_check_name "$router"
	[ -f "$LINK_CERT" ] || die "not provisioned — run: install.sh link"
	[ ! -f "$LINK_ROUTERS/$router.token" ] || die "router '$router' is already paired
revoke it first with: sdx link remove $router"

	token=$(head -c 32 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=')
	mkdir -p "$LINK_ROUTERS"
	chmod 700 "$LINK_ROUTERS"
	printf '%s' "$token" | sha256sum | awk '{print $1}' >"$LINK_ROUTERS/$router.token"
	chmod 600 "$LINK_ROUTERS/$router.token"

	local url fp
	url="https://$(get_ip):${LINK_PORT}"
	fp=$(_fingerprint)
	echo "Router '$router' paired."
	echo
	printf '%-13s %s\n' "URL:" "$url"
	printf '%-13s %s\n' "Token:" "$token"
	printf '%-13s %s\n' "Fingerprint:" "$fp"
	echo
	echo "On the router, run:"
	echo
	echo "  sdx link add $(server_name) $url $token $fp"
	echo
	echo "The token is shown once; pair again to get a new one."
}

svc_remove() {
	need_root
	local router="${1:-}"
	[ -n "$router" ] || usage "sdx link remove <router>"
	[ -f "$LINK_ROUTERS/$router.token" ] || die "router '$router' is not paired"
	rm -f "$LINK_ROUTERS/$router.token"
	echo "Router '$router' unpaired"
}

svc_rotate() {
	need_root
	rm -f "$LINK_CERT" "$LINK_KEY"
	_gen_cert
	if systemctl is-active --quiet "$SERVICE"; then
		systemctl restart "$SERVICE"
	fi
	echo "Certificate rotated: $(_fingerprint)"
	echo "Every paired router must be paired again with the new fingerprint."
}

svc_help() {
	cat <<EOF
start	Start the service
stop	Stop the service
restart	Restart the service
add <router>	Pair a router
remove <router>	Unpair a router
rotate	Regenerate the certificate	Regenerate the API certificate (every router must pair again)
EOF
}

svc_dispatch() {
	local action="$1"
	shift

	case "$action" in
	start) svc_start ;;
	stop) svc_stop ;;
	restart) svc_restart ;;
	status) svc_status ;;
	add) svc_add "$@" ;;
	remove) svc_remove "$@" ;;
	rotate) svc_rotate ;;
	*) return 127 ;;
	esac
}
