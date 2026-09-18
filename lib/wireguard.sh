# shellcheck shell=bash

[ -n "${SEEDEX_WIREGUARD_SH:-}" ] && return 0
SEEDEX_WIREGUARD_SH=1

WG_ROOT="/etc/seedex/vpn"
WG_LOG_DIR="/var/log/seedex-vpn"

wg_bind() {
	local proto="$1" action
	for action in port packages configured provision genconfig add remove export rotate config status start stop upgrade; do
		eval "vpn_${proto}_${action}() { wg_${action} $proto \"\$@\"; }"
	done
}

wg_profile() {
	WG_PROTO="$1"
	"vpn_${WG_PROTO}_profile"
	WG_DIR="$WG_ROOT/$WG_PROTO"
	WG_CONFIG="$WG_DIR/$WG_IFACE.conf"
	WG_CLIENTS="$WG_DIR/clients"
	WG_SERVICE="seedex-vpn-$WG_PROTO"
	WG_SERVICE_FILE="/etc/systemd/system/$WG_SERVICE.service"
	WG_LOG="$WG_LOG_DIR/$WG_PROTO.log"
}

_wg_hook() {
	local hook="vpn_${WG_PROTO}_$1"
	shift
	declare -F "$hook" >/dev/null || return 0
	"$hook" "$@"
}

_wg_load_params() {
	_wg_hook params_load
}

wg_port() {
	wg_profile "$1"
	printf '%s/udp:%s\n' "$WG_PORT" "$WG_TITLE"
}

wg_packages() {
	wg_profile "$1"
	_wg_hook install
}

wg_configured() {
	wg_profile "$1"
	[ -f "$WG_CONFIG" ]
}

_wg_render_config() {
	local priv="$1"
	{
		echo "[Interface]"
		echo "Address = ${WG_NET}.1/24, ${WG_NET6}::1/64"
		echo "ListenPort = $WG_PORT"
		echo "PrivateKey = $priv"
		_wg_hook params_block
		echo "PostUp = iptables -t nat -A POSTROUTING -s ${WG_NET}.0/24 ! -o $WG_IFACE -j MASQUERADE; ip6tables -t nat -A POSTROUTING -s ${WG_NET6}::/64 ! -o $WG_IFACE -j MASQUERADE"
		echo "PostDown = iptables -t nat -D POSTROUTING -s ${WG_NET}.0/24 ! -o $WG_IFACE -j MASQUERADE; ip6tables -t nat -D POSTROUTING -s ${WG_NET6}::/64 ! -o $WG_IFACE -j MASQUERADE"
	} >"$WG_CONFIG"
	chmod 600 "$WG_CONFIG"
}

wg_genconfig() {
	wg_profile "$1"
	need_root
	command -v "$WG_TOOL" >/dev/null 2>&1 || die "$WG_TOOL not found — run: install.sh vpn"
	if [ -f "$WG_CONFIG" ]; then
		echo "$WG_TITLE is configured already — 'sdx vpn rotate $WG_PROTO' regenerates it"
		return
	fi

	echo "Generating $WG_TITLE server config"
	mkdir -p "$WG_DIR"
	chmod 700 "$WG_DIR"

	local priv pub
	priv=$("$WG_TOOL" genkey)
	pub=$(echo "$priv" | "$WG_TOOL" pubkey)
	_wg_hook params_gen
	_wg_load_params
	_wg_render_config "$priv"
	echo 0 >"$WG_DIR/.next_client"
	echo "$pub" >"$WG_DIR/.server_pubkey"

	echo
	section "$WG_TITLE (${WG_PORT}/udp):"
	field "Public Key:" "$pub"
	field "Network:" "${WG_NET}.0/24, ${WG_NET6}::/64"
	_wg_hook params_print
}

_wg_install_service() {
	local quick
	quick=$(command -v "$WG_QUICK") || die "$WG_QUICK not found — run: install.sh vpn"
	cat >"$WG_SERVICE_FILE" <<EOF
[Unit]
Description=Seedex VPN ($WG_TITLE $WG_IFACE)
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$quick up $WG_CONFIG
ExecStop=$quick down $WG_CONFIG

[Install]
WantedBy=multi-user.target
EOF
	systemctl daemon-reload
	systemctl enable "$WG_SERVICE" >/dev/null 2>&1
}

wg_provision() {
	wg_profile "$1"
	need_root
	[ -f "$WG_CONFIG" ] || wg_genconfig "$WG_PROTO"
	[ -f "$WG_SERVICE_FILE" ] || _wg_install_service
	mkdir -p "$WG_LOG_DIR"
	vpn_host_provision
	firewall_allow "$(wg_port "$WG_PROTO")"
	firewall_route_allow "$WG_IFACE" "$WG_SERVICE"
	logrotate_install "$WG_SERVICE" "$WG_LOG"
}

wg_start() {
	wg_profile "$1"
	need_root
	[ -f "$WG_CONFIG" ] || die "$WG_PROTO is not configured — add a client first: sdx vpn add $WG_PROTO <name>"
	[ -f "$WG_SERVICE_FILE" ] || _wg_install_service
	if systemctl is-active --quiet "$WG_SERVICE"; then
		echo "$WG_PROTO: already running"
		return
	fi
	systemctl start "$WG_SERVICE"
	log_event "$WG_LOG" "Started $WG_IFACE"
	echo "$WG_PROTO: started"
}

wg_stop() {
	wg_profile "$1"
	need_root
	if ! systemctl is-active --quiet "$WG_SERVICE" 2>/dev/null; then
		echo "$WG_PROTO: not running"
		return
	fi
	systemctl stop "$WG_SERVICE"
	log_event "$WG_LOG" "Stopped $WG_IFACE"
	echo "$WG_PROTO: stopped"
}

wg_upgrade() {
	wg_profile "$1"
	vpn_host_provision
	_wg_hook maintain
}

wg_status() {
	wg_profile "$1"
	local up=0 f n=0
	systemctl is-active --quiet "$WG_SERVICE" 2>/dev/null && up=1
	printf '    %s %-14s %s/udp\n' "$(mark "$up")" "$WG_PROTO" "$WG_PORT"
	for f in "$WG_CLIENTS"/*.conf; do
		[ -f "$f" ] || continue
		printf '        %s\n' "$(basename "$f" .conf)"
		n=$((n + 1))
	done
	[ "$n" -gt 0 ] || printf '        %s\n' "no clients"
}

wg_config() {
	wg_profile "$1"
	[ -f "$WG_CONFIG" ] || return 0
	local server_ip pub
	server_ip=$(get_ip)
	pub=$(cat "$WG_DIR/.server_pubkey" 2>/dev/null || echo "<unknown>")
	section "$WG_TITLE (${WG_PORT}/udp):"
	field "Endpoint:" "${server_ip}:${WG_PORT}"
	field "Public Key:" "$pub"
	field "Network:" "${WG_NET}.0/24, ${WG_NET6}::/64"
	_wg_load_params
	_wg_hook params_print
	local f found=0
	for f in "$WG_CLIENTS"/*.conf; do
		[ -f "$f" ] || continue
		found=1
		printf '  %s:\n' "$(basename "$f" .conf)"
		indent <"$f" | indent
	done
	[ "$found" = 1 ] || printf '  %s\n' "no clients"
}

wg_add() {
	wg_profile "$1"
	need_root
	local name="${2:-}"
	case "$name" in
	"") ;;
	*[!A-Za-z0-9._-]* | -*) die "invalid client name '$name' — use letters, digits, dot, dash or underscore" ;;
	esac
	[ -f "$WG_CONFIG" ] || wg_provision "$WG_PROTO"

	local next
	next=$(cat "$WG_DIR/.next_client")
	next=$((next + 1))
	[ -n "$name" ] || {
		name="$WG_PROTO"
		[ "$next" -eq 1 ] || name="$WG_PROTO-$next"
	}
	[ ! -f "$WG_CLIENTS/$name.conf" ] || die "client '$name' already exists"
	_wg_load_params

	local host=$((next + 1))
	[ "$host" -le 254 ] || die "no free addresses left in ${WG_NET}.0/24"

	local priv pub psk server_pub server_ip addr allowed
	priv=$("$WG_TOOL" genkey)
	pub=$(echo "$priv" | "$WG_TOOL" pubkey)
	psk=$("$WG_TOOL" genpsk)
	server_pub=$(cat "$WG_DIR/.server_pubkey")
	server_ip=$(get_ip)
	addr="${WG_NET}.${host}/32, ${WG_NET6}::${host}/128"
	allowed="${WG_NET}.${host}/32,${WG_NET6}::${host}/128"

	cat >>"$WG_CONFIG" <<EOF

# $name
[Peer]
PublicKey = $pub
PresharedKey = $psk
AllowedIPs = ${WG_NET}.${host}/32, ${WG_NET6}::${host}/128
EOF

	mkdir -p "$WG_CLIENTS"
	{
		echo "[Interface]"
		echo "PrivateKey = $priv"
		echo "Address = $addr"
		echo "DNS = 1.1.1.1, 1.0.0.1"
		_wg_hook params_block
		echo
		echo "[Peer]"
		echo "PublicKey = $server_pub"
		echo "PresharedKey = $psk"
		echo "Endpoint = ${server_ip}:${WG_PORT}"
		echo "AllowedIPs = 0.0.0.0/0, ::/0"
		echo "PersistentKeepalive = 25"
	} >"$WG_CLIENTS/$name.conf"
	chmod 600 "$WG_CLIENTS/$name.conf"
	echo "$next" >"$WG_DIR/.next_client"

	if ip link show "$WG_IFACE" &>/dev/null; then
		local pskfile
		pskfile=$(mktemp)
		echo "$psk" >"$pskfile"
		"$WG_TOOL" set "$WG_IFACE" peer "$pub" preshared-key "$pskfile" allowed-ips "$allowed"
		rm -f "$pskfile"
		log_event "$WG_LOG" "Added client '$name' (hot-reload)"
	else
		log_event "$WG_LOG" "Added client '$name'"
	fi

	echo "added $WG_PROTO client '$name'"
	field "Config:" "$WG_CLIENTS/$name.conf"
}

_wg_client_pubkey() {
	awk -v want="# $1" '
		$0 == want { inblock = 1; next }
		inblock && /^# / { exit }
		inblock && /^PublicKey/ { print $3; exit }
	' "$WG_CONFIG"
}

_wg_drop_peer() {
	local tmp
	tmp=$(mktemp)
	awk -v want="# $1" '
		$0 == want { skip = 1; next }
		skip && /^# / { skip = 0 }
		!skip { print }
	' "$WG_CONFIG" | cat -s >"$tmp"
	cat "$tmp" >"$WG_CONFIG"
	rm -f "$tmp"
}

wg_remove() {
	wg_profile "$1"
	need_root
	shift
	local all=0 name=""
	while [ $# -gt 0 ]; do
		case "$1" in
		--all) all=1 ;;
		-*) usage "sdx vpn remove $WG_PROTO {<name>|--all}" ;;
		*) name="$1" ;;
		esac
		shift
	done
	[ -n "$name" ] || [ "$all" = 1 ] || usage "sdx vpn remove $WG_PROTO {<name>|--all}"
	[ -f "$WG_CONFIG" ] || die "$WG_PROTO is not configured"

	local -a targets=()
	local f
	if [ "$all" = 1 ]; then
		for f in "$WG_CLIENTS"/*.conf; do
			[ -f "$f" ] || continue
			targets+=("$(basename "$f" .conf)")
		done
		[ "${#targets[@]}" -gt 0 ] || die "no clients to remove"
	else
		[ -f "$WG_CLIENTS/$name.conf" ] || die "client '$name' not found"
		targets=("$name")
	fi

	backup_file "$WG_CONFIG"
	local c pub
	for c in "${targets[@]}"; do
		pub=$(_wg_client_pubkey "$c")
		_wg_drop_peer "$c"
		rm -f "$WG_CLIENTS/$c.conf"
		if [ -n "$pub" ] && ip link show "$WG_IFACE" &>/dev/null; then
			"$WG_TOOL" set "$WG_IFACE" peer "$pub" remove
			log_event "$WG_LOG" "Removed client '$c' (hot-reload)"
		else
			log_event "$WG_LOG" "Removed client '$c'"
		fi
		echo "removed $WG_PROTO client '$c'"
	done
}

wg_clients() {
	local f
	for f in "$WG_CLIENTS"/*.conf; do
		[ -f "$f" ] || continue
		basename "$f" .conf
	done
}

wg_export() {
	wg_profile "$1"
	shift
	local name="${1:-}" dir="${2:-}" c first=1 path
	local -a clients=()
	if [ -n "$name" ]; then
		[ -f "$WG_CLIENTS/$name.conf" ] || die "$WG_PROTO client '$name' not found"
		clients=("$name")
	else
		mapfile -t clients < <(wg_clients)
		[ "${#clients[@]}" -gt 0 ] || die "$WG_PROTO has no clients — run: sdx vpn add $WG_PROTO <name>"
	fi
	for c in "${clients[@]}"; do
		if [ -n "$dir" ]; then
			mkdir -p "$dir"
			path="$dir/$(config_basename "$WG_PROTO-$c").conf"
			cp "$WG_CLIENTS/$c.conf" "$path"
			chmod 600 "$path"
			echo "$path"
		else
			[ "$first" = 1 ] || echo
			echo "# $WG_PROTO $c"
			cat "$WG_CLIENTS/$c.conf"
			first=0
		fi
	done
}

wg_rotate() {
	wg_profile "$1"
	need_root
	[ -f "$WG_CONFIG" ] || die "$WG_PROTO is not configured"
	local was_running=0
	systemctl is-active --quiet "$WG_SERVICE" 2>/dev/null && was_running=1
	[ "$was_running" = 0 ] || wg_stop "$WG_PROTO" >/dev/null
	backup_file "$WG_CONFIG"
	rm -f "$WG_CONFIG" "$WG_DIR/.next_client" "$WG_DIR/.server_pubkey"
	rm -rf "$WG_CLIENTS"
	_wg_hook params_reset
	wg_genconfig "$WG_PROTO"
	[ "$was_running" = 0 ] || wg_start "$WG_PROTO"
	echo
	echo "$WG_PROTO rotated — every client must be added again: sdx vpn add $WG_PROTO <name>"
}
