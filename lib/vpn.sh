# shellcheck shell=bash

SVC_ACTIONS="start stop restart config export rotate add remove"

VPN_MODULES_DIR="$(dirname "${BASH_SOURCE[0]}")/vpn"
VPN_PROTOCOLS=""
for _vpn_module in "$VPN_MODULES_DIR"/*.sh; do
	# shellcheck disable=SC1090
	. "$_vpn_module"
	_vpn_proto="$(basename "$_vpn_module" .sh)"
	VPN_PROTOCOLS="${VPN_PROTOCOLS:+$VPN_PROTOCOLS }$_vpn_proto"
done
unset _vpn_module _vpn_proto

_vpn_known() {
	case " $VPN_PROTOCOLS " in
	*" $1 "*) return 0 ;;
	esac
	return 1
}

_vpn_call() {
	local proto="$1" action="$2"
	shift 2
	_vpn_known "$proto" || die "unknown protocol '$proto' — one of: $VPN_PROTOCOLS"
	"vpn_${proto}_${action}" "$@"
}

_vpn_configured() {
	local p
	for p in $VPN_PROTOCOLS; do
		"vpn_${p}_configured" && echo "$p"
	done
	return 0
}

_vpn_port_specs() {
	local p
	for p in $(_vpn_configured); do
		"vpn_${p}_port"
	done
}

_vpn_targets() {
	if [ -n "${1:-}" ]; then
		_vpn_known "$1" || die "unknown protocol '$1' — one of: $VPN_PROTOCOLS"
		"vpn_${1}_configured" || die "$1 is not configured — add a client first: sdx vpn add $1 <name>"
		echo "$1"
		return
	fi
	_vpn_configured
}

_vpn_retire_legacy() {
	local p
	if [ -f /etc/systemd/system/seedex-vpn.service ]; then
		systemctl is-active --quiet seedex-vpn 2>/dev/null && VPN_LEGACY_RUNNING=1
		systemctl disable --now seedex-vpn >/dev/null 2>&1 || true
		rm -f /etc/systemd/system/seedex-vpn.service
		systemctl daemon-reload
		echo "  retired the pre-module seedex-vpn unit"
	fi
	for p in $VPN_PROTOCOLS; do
		declare -F "vpn_${p}_migrate" >/dev/null || continue
		"vpn_${p}_migrate"
	done
}

vpn_forwarding_enable() {
	local key changed=0
	for key in net.ipv4.ip_forward net.ipv6.conf.all.forwarding; do
		grep -q "^${key}=1" /etc/sysctl.conf 2>/dev/null && continue
		echo "${key}=1" >>/etc/sysctl.conf
		changed=1
	done
	[ "$changed" = 1 ] || [ "$(sysctl -n net.ipv4.ip_forward)" != 1 ] || return 1
	sysctl -p >/dev/null
}

vpn_host_provision() {
	need_root
	vpn_forwarding_enable || true
	firewall_apply
}

svc_provision() {
	need_root
	local p
	_vpn_retire_legacy
	echo "[1/3] Checking packages..."
	for p in $VPN_PROTOCOLS; do
		echo "  $p:"
		"vpn_${p}_packages"
	done

	echo "[2/3] Enabling IP forwarding..."
	if vpn_forwarding_enable; then
		echo "  Enabled"
	else
		echo "  Already enabled"
	fi

	echo "[3/3] Configuring firewall..."
	firewall_apply
	echo "  Enabled"

	echo "Configured protocols:"
	local n=0
	for p in $(_vpn_configured); do
		"vpn_${p}_provision"
		echo "  $p"
		n=$((n + 1))
	done
	[ "$n" -gt 0 ] || echo "  none yet — add a client with: sdx vpn add <protocol> <name>  (protocols: $VPN_PROTOCOLS)"
}

svc_upgrade() {
	local p
	_vpn_retire_legacy
	for p in $VPN_PROTOCOLS; do
		"vpn_${p}_packages"
	done
	for p in $(_vpn_configured); do
		"vpn_${p}_upgrade"
		[ "${VPN_LEGACY_RUNNING:-0}" = 0 ] || "vpn_${p}_active" || "vpn_${p}_start"
	done
}

svc_start() {
	local p n=0
	for p in $(_vpn_targets "${1:-}"); do
		"vpn_${p}_start"
		n=$((n + 1))
	done
	[ "$n" -gt 0 ] || echo "no protocols configured — add a client with: sdx vpn add <protocol> <name>"
}

svc_stop() {
	local p
	for p in $(_vpn_targets "${1:-}"); do
		"vpn_${p}_stop"
	done
}

svc_restart() {
	local p
	for p in $(_vpn_targets "${1:-}"); do
		"vpn_${p}_stop" >/dev/null
		"vpn_${p}_start"
	done
}

svc_status() {
	local p up=0 n=0
	for p in $(_vpn_configured); do
		"vpn_${p}_active" && up=1
		n=$((n + 1))
	done
	status_header "VPN" "$up"
	if [ "$n" -eq 0 ]; then
		field "Protocols:" "none"
		return
	fi
	echo "  Protocols:"
	for p in $(_vpn_configured); do
		"vpn_${p}_status"
	done
}

svc_config() {
	local p n=0
	section "Server:"
	printf '  %s\n' "$(get_ip)"
	for p in $(_vpn_targets "${1:-}"); do
		"vpn_${p}_config"
		n=$((n + 1))
	done
	[ "$n" -gt 0 ] || printf '  %s\n' "no protocols configured"
}

svc_add() {
	local proto="${1:-}" name="${2:-}"
	[ -n "$proto" ] || usage "sdx vpn add <protocol> [<name>]   (protocols: $VPN_PROTOCOLS)"
	_vpn_call "$proto" add "$name"
}

svc_remove() {
	local proto="${1:-}"
	[ -n "$proto" ] && [ $# -ge 2 ] || usage "sdx vpn remove <protocol> {<name>|--all}"
	shift
	_vpn_call "$proto" remove "$@"
}

svc_export() {
	local proto="" name="" dir="" p
	while [ $# -gt 0 ]; do
		case "$1" in
		-o | --output)
			[ $# -ge 2 ] || usage "sdx vpn export [<protocol> [<name>]] [-o DIR]"
			dir="${2%/}"
			shift
			;;
		-*) usage "sdx vpn export [<protocol> [<name>]] [-o DIR]" ;;
		*)
			if [ -z "$proto" ]; then
				proto="$1"
			else
				name="$1"
			fi
			;;
		esac
		shift
	done
	local first=1
	for p in $(_vpn_targets "$proto"); do
		[ "$first" = 1 ] || [ -n "$dir" ] || echo
		"vpn_${p}_export" "$name" "$dir"
		first=0
	done
	[ "$first" = 0 ] || die "no protocols configured — add a client with: sdx vpn add <protocol> <name>"
}

svc_rotate() {
	local p
	for p in $(_vpn_targets "${1:-}"); do
		"vpn_${p}_rotate"
	done
}

svc_help() {
	cat <<EOF
start [<protocol>]	Start the service	Start every configured protocol, or one
stop [<protocol>]	Stop the service	Stop every configured protocol, or one
restart [<protocol>]	Restart the service	Restart every configured protocol, or one
config [<protocol>]	Show connection credentials
export [<protocol> [<name>]] [-o DIR]	Export client configs	Export client configs, all or one protocol or one client, to DIR
rotate [<protocol>]	Regenerate credentials	Regenerate keys and params (breaks every client of the protocol)
add <protocol> [<name>]	Add a client	Add a client; protocols: $VPN_PROTOCOLS
remove <protocol> {<name>|--all}	Revoke a client
EOF
}

svc_dispatch() {
	local action="$1"
	shift

	case "$action" in
	start) svc_start "$@" ;;
	stop) svc_stop "$@" ;;
	restart) svc_restart "$@" ;;
	status) svc_status ;;
	config) svc_config "$@" ;;
	export) svc_export "$@" ;;
	rotate) svc_rotate "$@" ;;
	add) svc_add "$@" ;;
	remove) svc_remove "$@" ;;
	*) die "unknown action: $action" ;;
	esac
}
