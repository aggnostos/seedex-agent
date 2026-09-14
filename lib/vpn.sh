# shellcheck shell=bash

SVC_ACTIONS="start stop restart config export rotate add remove"

AWG_DIR="/etc/amnezia/amneziawg"
AWG_CONFIG="$AWG_DIR/awg0.conf"
AWG_CLIENTS="$AWG_DIR/clients"

AWG_IFACE="awg0"
AWG_NET="10.66.67"
AWG_NET6="fd5e:ede0"
AWG_PORT="${SEEDEX_PORTS_VPN%%/*}"

AWG_PARAMS="$AWG_DIR/.awg_params"

AWG_MIN_BUILD="${SEEDEX_AWG_MIN_BUILD:-202608130141}"

AWG_I1_DOMAINS="yandex.ru vk.com mail.ru ok.ru dzen.ru avito.ru ozon.ru rutube.ru kinopoisk.ru gosuslugi.ru"

_pick() {
	local n
	n=$(_rand_between 1 $#)
	eval "printf '%s\\n' \"\${$n}\""
}

_gen_i1() {
	local domain label qname="" ttl ip
	# shellcheck disable=SC2086
	domain=$(_pick $AWG_I1_DOMAINS)
	for label in $(echo "$domain" | tr '.' ' '); do
		qname="${qname}$(printf '%02x' "${#label}")$(printf '%s' "$label" | od -An -tx1 | tr -d ' \n')"
	done
	ttl=$(printf '%08x' "$(_rand_between 60 3600)")
	ip=$(printf '%02x%02x%02x%02x' "$(_pick 5 77 87 93 178 185 213)" \
		"$(_rand_between 1 254)" "$(_rand_between 1 254)" "$(_rand_between 1 254)")
	printf '<r 2><b 0x81800001000100000000%s0000010001c00c00010001%s0004%s>\n' "$qname" "$ttl" "$ip"
}

SERVICE="seedex-vpn"
SERVICE_FILE="/etc/systemd/system/${SERVICE}.service"

LOG_DIR="/var/log/seedex-vpn"
LOG_FILE="$LOG_DIR/vpn.log"

_gen_awg_params() {
	local jc jmin jmax s1 s2 s3 s4
	local h_lo=5 h_hi=2147483647 band i
	local h_start h_end
	local -a h_range=()

	jc=$(_rand_between 3 6)
	jmin=$(_rand_between 64 256)
	jmax=$(_rand_between $((jmin + 128)) 1024)

	s1=$(_rand_between 15 64)
	while :; do
		s2=$(_rand_between 15 64)
		[ $((s1 + 56)) -ne "$s2" ] && break
	done
	s3=$(_rand_between 15 64)
	s4=$(_rand_between 8 32)

	band=$(((h_hi - h_lo) / 4))
	for i in 0 1 2 3; do
		local base=$((h_lo + i * band))
		h_start=$(_rand_between "$base" $((base + band / 2)))
		h_end=$((h_start + $(_rand_between 100000 1000000)))
		h_range+=("${h_start}-${h_end}")
	done

	local i1=""
	if _awg_has_cps; then
		i1=$(_gen_i1)
	else
		echo "  note: this build rejects CPS packets — I1 left unset" >&2
	fi

	cat <<EOF
AWG_PARAMS_VERSION=2
Jc=$jc
Jmin=$jmin
Jmax=$jmax
S1=$s1
S2=$s2
S3=$s3
S4=$s4
H1=${h_range[0]}
H2=${h_range[1]}
H3=${h_range[2]}
H4=${h_range[3]}
I1='$i1'
EOF
}

AWG_PPA="ppa:amnezia/ppa"
AWG_PACKAGES="amneziawg amneziawg-dkms amneziawg-tools"

AWG_PPA_SUITE="${AWG_PPA_SUITE:-}"

_awg_pin() {
	[ -z "${AWG_VERSION:-}" ] || {
		echo "$AWG_VERSION"
		return
	}
	case "$1" in
	amneziawg) echo "${SEEDEX_AWG_VERSION:-}" ;;
	amneziawg-dkms) echo "${SEEDEX_AWG_DKMS_VERSION:-}" ;;
	amneziawg-tools) echo "${SEEDEX_AWG_TOOLS_VERSION:-}" ;;
	esac
}

_awg_build() {
	printf '%s\n' "$1" | sed -n 's/^[^~]*~\([0-9]\{12\}\).*/\1/p'
}

_awg_check_floor() {
	local pkg="$1" version="$2" build floor="$AWG_MIN_BUILD"
	[ -n "$floor" ] || return 0
	build=$(_awg_build "$version")
	[ -n "$build" ] || {
		warn "$pkg $version: cannot read a build stamp, skipping the floor check"
		return 0
	}
	[ "$build" -ge "$floor" ] && return 0
	warn "$pkg $version is older than the tested baseline ($floor)."
	warn "The PPA does not build every series equally often; this one is behind."
	warn "Either pick a series with a current build:"
	warn "  AWG_PPA_SUITE=noble ./install.sh vpn"
	die "or accept the older build with SEEDEX_AWG_MIN_BUILD=0."
}

_pkg_installed() { dpkg-query -W -f='${Version}' "$1" 2>/dev/null || true; }
_pkg_candidate() { apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/ {print $2}'; }

_install_packages() {
	need_root
	export DEBIAN_FRONTEND=noninteractive

	echo "[1/3] Configuring repository..."
	command -v add-apt-repository >/dev/null 2>&1 ||
		apt-get install -y -qq software-properties-common ||
		die "cannot install software-properties-common"
	add-apt-repository -y "$AWG_PPA" >/dev/null ||
		die "cannot add $AWG_PPA — check outbound access to launchpad.net"

	if [ -n "$AWG_PPA_SUITE" ]; then
		echo "  pinning the PPA to '$AWG_PPA_SUITE'"
		sed -i "s/^Suites: .*/Suites: $AWG_PPA_SUITE/" \
			/etc/apt/sources.list.d/amnezia-ubuntu-ppa-*.sources 2>/dev/null ||
			warn "could not repoint the PPA sources file"
	fi

	apt-get update -qq ||
		echo "  warning: apt-get update reported errors" >&2

	echo "[2/3] Resolving versions..."
	local pkg installed candidate want stale=0
	for pkg in $AWG_PACKAGES; do
		want=$(_awg_pin "$pkg")
		candidate=$(_pkg_candidate "$pkg")
		[ -n "$candidate" ] && [ "$candidate" != "(none)" ] || {
			local series
			series=$(lsb_release -cs 2>/dev/null || echo 'this release')
			warn "$pkg is not offered by $AWG_PPA on $series."
			warn "The PPA does not build for every release. Pick a series it has"
			warn "— see https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu/dists/ —"
			warn "and rerun, e.g.:"
			die "  AWG_PPA_SUITE=noble ./install.sh vpn"
		}
		installed=$(_pkg_installed "$pkg")
		_awg_check_floor "$pkg" "${want:-$candidate}"

		if [ -n "$want" ]; then
			if [ "$installed" = "$want" ]; then
				echo "  $pkg $installed (pinned)"
				continue
			fi
			apt-cache madison "$pkg" 2>/dev/null | grep -q " $want " || {
				local offered
				offered=$(apt-cache madison "$pkg" 2>/dev/null |
					awk -F'|' '{gsub(/^ +| +$/, "", $2); print "    " $2}')
				warn "$pkg $want is not available in $AWG_PPA."
				warn "The PPA keeps only the latest build, so pins expire."
				warn "Currently offered:"
				printf '%s\n' "$offered" >&2
				die "Unset the pin, or set it to one of the versions above."
			}
			echo "  $pkg ${installed:-none} -> $want (pinned)"
			stale=1
			continue
		fi

		if [ "$installed" = "$candidate" ]; then
			echo "  $pkg $installed (current)"
		else
			echo "  $pkg ${installed:-none} -> $candidate"
			stale=1
		fi
	done

	if [ "$stale" -eq 0 ]; then
		echo "[3/3] Up to date."
		_check_module_reload
		return
	fi

	echo "[3/3] Installing..."
	local spec="" pkg2 pin
	for pkg2 in $AWG_PACKAGES; do
		pin=$(_awg_pin "$pkg2")
		spec="$spec ${pkg2}${pin:+=$pin}"
	done
	# shellcheck disable=SC2086
	apt-get install -y -qq $spec ||
		die "apt-get install failed — rerun without -qq to see the reason"

	command -v awg >/dev/null 2>&1 || die "awg missing after install"
	_check_module_reload
	echo "Installed: $(awg --version 2>/dev/null)"
}

_check_module_reload() {
	[ -d /sys/module/amneziawg ] || return 0

	local on_disk loaded
	on_disk=$(modinfo -F srcversion amneziawg 2>/dev/null || true)
	loaded=$(cat /sys/module/amneziawg/srcversion 2>/dev/null || true)
	[ -n "$on_disk" ] && [ -n "$loaded" ] || return 0
	[ "$on_disk" != "$loaded" ] || return 0

	if ip link show "$AWG_IFACE" >/dev/null 2>&1; then
		echo "  note: a newer kernel module is installed but $AWG_IFACE is up," >&2
		echo "  so the old one is still resident. Load it with:" >&2
		echo "    sdx vpn stop && ./install.sh vpn && sdx vpn start" >&2
		return 0
	fi

	echo "  reloading kernel module"
	modprobe -r amneziawg 2>/dev/null && modprobe amneziawg 2>/dev/null ||
		echo "  warning: could not reload amneziawg; reboot to pick it up" >&2
}

_awg_has_cps() {
	command -v awg >/dev/null 2>&1 || return 1
	command -v ip >/dev/null 2>&1 || return 1

	local dev="awgcps$$" conf rc=1
	ip link add dev "$dev" type amneziawg >/dev/null 2>&1 || return 1

	conf=$(mktemp)
	cat >"$conf" <<EOF
[Interface]
PrivateKey = $(awg genkey)
I1 = $(_gen_i1)
EOF
	awg setconf "$dev" "$conf" >/dev/null 2>&1 && rc=0

	rm -f "$conf"
	ip link del "$dev" >/dev/null 2>&1
	return "$rc"
}

_load_params() {
	[ -f "$AWG_PARAMS" ] || die "AWG params missing — run: install.sh"
	# shellcheck disable=SC1090
	. "$AWG_PARAMS"
	if [ "${AWG_PARAMS_VERSION:-1}" != "2" ]; then
		warn "this server still holds AmneziaWG 1.x parameters."
		warn "2.0 is a different protocol — existing clients cannot be"
		warn "upgraded in place. Reissue them:"
		printf '  %s\n' \
			"./install.sh vpn       # pull 2.0 from the PPA" \
			"sdx vpn rotate      # new keys + 2.0 params" \
			"sdx vpn add" >&2
		exit 1
	fi
}

# shellcheck disable=SC2154
_params_block() {
	printf 'Jc = %s\nJmin = %s\nJmax = %s\n' "$Jc" "$Jmin" "$Jmax"
	printf 'S1 = %s\nS2 = %s\nS3 = %s\nS4 = %s\n' "$S1" "$S2" "$S3" "$S4"
	printf 'H1 = %s\nH2 = %s\nH3 = %s\nH4 = %s\n' "$H1" "$H2" "$H3" "$H4"
	[ -n "$I1" ] || return 0
	printf 'I1 = %s\n' "$I1"
}

_render_config() {
	local priv="$1"

	cat >"$AWG_CONFIG" <<EOF
[Interface]
Address = ${AWG_NET}.1/24, ${AWG_NET6}::1/64
ListenPort = $AWG_PORT
PrivateKey = $priv
$(_params_block)
PostUp = iptables -t nat -A POSTROUTING -s ${AWG_NET}.0/24 ! -o $AWG_IFACE -j MASQUERADE; ip6tables -t nat -A POSTROUTING -s ${AWG_NET6}::/64 ! -o $AWG_IFACE -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -s ${AWG_NET}.0/24 ! -o $AWG_IFACE -j MASQUERADE; ip6tables -t nat -D POSTROUTING -s ${AWG_NET6}::/64 ! -o $AWG_IFACE -j MASQUERADE
EOF
}

_print_params() {
	echo
	section "AmneziaWG (${AWG_PORT}/udp):"
	field "Public Key:" "$1"
	field "Listen Port:" "$AWG_PORT"
	field "Network:" "${AWG_NET}.0/24, ${AWG_NET6}::/64"
	section "AWG Params (2.0):"
	printf '  %s\n' "Jc=$Jc  Jmin=$Jmin  Jmax=$Jmax"
	printf '  %s\n' "S1=$S1  S2=$S2  S3=$S3  S4=$S4"
	printf '  %s\n' "H1=$H1  H2=$H2"
	printf '  %s\n' "H3=$H3  H4=$H4"
}

_genconfig() {
	need_root

	if ! command -v awg &>/dev/null; then
		die "amneziawg-tools not found — run: install.sh"
	fi

	if [ -f "$AWG_CONFIG" ]; then
		echo "Config already exists — skipping."
		echo "Delete manually or use 'sdx vpn rotate' to regenerate."
		return
	fi

	echo "Generating AmneziaWG server config"
	mkdir -p "$AWG_DIR"
	chmod 700 "$AWG_DIR"

	local awg_priv awg_pub
	awg_priv=$(awg genkey)
	awg_pub=$(echo "$awg_priv" | awg pubkey)

	_gen_awg_params >"$AWG_PARAMS"
	chmod 600 "$AWG_PARAMS"

	# shellcheck disable=SC1090
	. "$AWG_PARAMS"

	_render_config "$awg_priv"
	chmod 600 "$AWG_CONFIG"

	echo "0" >"$AWG_DIR/.next_client"
	echo "$awg_pub" >"$AWG_DIR/.server_pubkey"

	_print_params "$awg_pub"
}

svc_upgrade() {
	local installed build floor="$AWG_MIN_BUILD"
	installed=$(_pkg_installed amneziawg-dkms)
	[ -n "$installed" ] && [ -n "$floor" ] || return 0
	build=$(_awg_build "$installed")
	[ -n "$build" ] && [ "$build" -lt "$floor" ] || return 0
	warn "amneziawg-dkms $installed is older than the tested baseline ($floor);"
	warn "upgrade it with: sdx vpn stop && install.sh vpn && sdx vpn start"
}

svc_provision() {
	need_root

	echo "[1/6] Checking packages..."
	_install_packages

	echo "[2/6] Setting up log directory..."
	mkdir -p "$LOG_DIR"
	echo "  $LOG_DIR"

	echo "[3/6] Checking configuration..."
	_genconfig

	echo "[4/6] Installing service..."
	_install_service
	echo "  Service installed and enabled (starts on boot)"

	echo "[5/6] Enabling IP forwarding..."
	local key changed=0
	for key in net.ipv4.ip_forward net.ipv6.conf.all.forwarding; do
		grep -q "^${key}=1" /etc/sysctl.conf 2>/dev/null && continue
		echo "${key}=1" >>/etc/sysctl.conf
		changed=1
	done
	if [ "$changed" = 1 ]; then
		sysctl -p >/dev/null
		echo "  Enabled"
	else
		echo "  Already enabled"
	fi

	echo "[6/6] Configuring firewall and logrotate..."
	# shellcheck disable=SC2086  # specs are deliberately word-split
	firewall_apply $SEEDEX_PORTS_BASE $SEEDEX_PORTS_VPN
	firewall_route_allow "$AWG_IFACE" "seedex-vpn"
	echo "  Firewall configured"

	logrotate_install seedex-vpn "$LOG_FILE"
	echo "  Logrotate configured"

	if ls "$AWG_CLIENTS"/*.conf &>/dev/null; then
		echo
		echo "  Clients already exist, skipping"
	else
		echo
		svc_add_client
	fi
}

_install_service() {
	need_root

	local awgq
	awgq=$(command -v awg-quick) || {
		warn "awg-quick not found; run install.sh first"
		return 1
	}

	cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=Seedex VPN (AmneziaWG $AWG_IFACE)
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$awgq up $AWG_IFACE
ExecStop=$awgq down $AWG_IFACE

[Install]
WantedBy=multi-user.target
EOF

	systemctl daemon-reload
	systemctl enable "$SERVICE" >/dev/null 2>&1
}

_ensure_service() {
	[ -f "$SERVICE_FILE" ] || _install_service
}

svc_start() {
	need_root
	_ensure_service
	if systemctl is-active --quiet "$SERVICE"; then
		echo "Already running"
		return
	fi
	systemctl start "$SERVICE"
	log_event "$LOG_FILE" "Started $AWG_IFACE"
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
	log_event "$LOG_FILE" "Stopped $AWG_IFACE"
	echo "Stopped"
}

svc_restart() {
	need_root
	_ensure_service
	systemctl restart "$SERVICE"
	log_event "$LOG_FILE" "Restarted $AWG_IFACE"
	echo "Restarted"
}

svc_status() {
	local up=0
	systemctl is-active --quiet "$SERVICE" && up=1
	status_header "VPN" "$up"
	[ "$up" = 0 ] || field "Interface:" "$AWG_IFACE"
	field "Port:" "${SEEDEX_PORTS_VPN%%:*}"
	[ -f "$AWG_CONFIG" ] || field "Config:" "missing (run: ./install.sh vpn)"
	local f n=0
	for f in "$AWG_CLIENTS"/*.conf; do
		[ -f "$f" ] || continue
		[ "$n" -gt 0 ] || echo "  Clients:"
		printf '    %s\n' "$(basename "$f" .conf)"
		n=$((n + 1))
	done
	[ "$n" -gt 0 ] || field "Clients:" "none"
}

svc_config() {
	if [ ! -f "$AWG_CONFIG" ]; then
		die "not configured — run: install.sh"
	fi

	local server_ip server_port server_pubkey
	server_ip=$(get_ip)
	server_port=$(grep -oP 'ListenPort\s*=\s*\K\d+' "$AWG_CONFIG" || echo "$AWG_PORT")
	server_pubkey="<unknown>"
	[ -f "$AWG_DIR/.server_pubkey" ] && server_pubkey=$(cat "$AWG_DIR/.server_pubkey")

	section "Server:"
	printf '  %s\n' "$server_ip"

	echo "AmneziaWG (${AWG_PORT}/udp):"
	field "Endpoint:" "${server_ip}:${server_port}"
	field "Public Key:" "$server_pubkey"
	field "Network:" "${AWG_NET}.0/24, ${AWG_NET6}::/64"

	if [ -f "$AWG_PARAMS" ]; then
		_load_params
		echo "AWG Params (2.0):"
		printf '  %s\n' "Jc=$Jc  Jmin=$Jmin  Jmax=$Jmax"
		printf '  %s\n' "S1=$S1  S2=$S2  S3=$S3  S4=$S4"
		printf '  %s\n' "H1=$H1  H2=$H2"
		printf '  %s\n' "H3=$H3  H4=$H4"
	fi

	section "Clients:"
	if [ ! -d "$AWG_CLIENTS" ]; then
		printf '  %s\n' "no clients"
		return
	fi

	local found=0
	for f in "$AWG_CLIENTS"/*.conf; do
		[ -f "$f" ] || continue
		found=1
		printf '  %s\n' "$(basename "$f" .conf):"
		indent <"$f" | indent
	done

	if [ "$found" -eq 0 ]; then
		printf '  %s\n' "no clients"
	fi
}

svc_add_client() {
	need_root

	local want_name="${1:-}"
	case "$want_name" in
	"") ;;
	*[!A-Za-z0-9._-]* | -*)
		die "invalid client name '$want_name' — use letters, digits, dot, dash or underscore"
		;;
	esac

	if [ ! -f "$AWG_CONFIG" ]; then
		die "not configured — run: install.sh"
	fi
	if [ ! -f "$AWG_DIR/.next_client" ] || [ ! -f "$AWG_DIR/.server_pubkey" ]; then
		die "metadata missing — run: install.sh"
	fi

	local next_num
	next_num=$(cat "$AWG_DIR/.next_client")
	next_num=$((next_num + 1))

	local client_name="$want_name"
	if [ -z "$client_name" ]; then
		client_name="AWG"
		[ "$next_num" -gt 1 ] && client_name="AWG-${next_num}"
	fi

	if [ -f "$AWG_CLIENTS/${client_name}.conf" ]; then
		die "client '$client_name' already exists"
	fi

	_load_params

	local server_pubkey
	server_pubkey=$(cat "$AWG_DIR/.server_pubkey")

	local client_ip=$((next_num + 1))
	if [ "$client_ip" -gt 254 ]; then
		die "no available IPs in ${AWG_NET}.0/24"
	fi

	local client_priv client_pub client_psk client_addr client_allowed
	client_priv=$(awg genkey)
	client_pub=$(echo "$client_priv" | awg pubkey)
	client_psk=$(awg genpsk)
	client_addr="${AWG_NET}.${client_ip}/32, ${AWG_NET6}::${client_ip}/128"
	client_allowed="${AWG_NET}.${client_ip}/32,${AWG_NET6}::${client_ip}/128"

	local server_ip server_port
	server_ip=$(get_ip)
	server_port=$(grep -oP 'ListenPort\s*=\s*\K\d+' "$AWG_CONFIG" || echo "0")

	cat >>"$AWG_CONFIG" <<EOF

# $client_name
[Peer]
PublicKey = $client_pub
PresharedKey = $client_psk
AllowedIPs = ${AWG_NET}.${client_ip}/32, ${AWG_NET6}::${client_ip}/128
EOF

	mkdir -p "$AWG_CLIENTS"

	cat >"$AWG_CLIENTS/${client_name}.conf" <<EOF
[Interface]
PrivateKey = $client_priv
Address = $client_addr
DNS = 1.1.1.1, 1.0.0.1
$(_params_block)

[Peer]
PublicKey = $server_pubkey
PresharedKey = $client_psk
Endpoint = ${server_ip}:${server_port}
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF
	chmod 600 "$AWG_CLIENTS/${client_name}.conf"

	echo "$next_num" >"$AWG_DIR/.next_client"

	if ip link show "$AWG_IFACE" &>/dev/null; then
		local pskfile
		pskfile=$(mktemp)
		echo "$client_psk" >"$pskfile"
		awg set "$AWG_IFACE" peer "$client_pub" \
			preshared-key "$pskfile" \
			allowed-ips "$client_allowed"
		rm -f "$pskfile"
		log_event "$LOG_FILE" "Added client '$client_name' (hot-reload)"
	else
		log_event "$LOG_FILE" "Added client '$client_name' (restart needed)"
	fi

	echo
	echo "Client '$client_name' created"
	echo
	section "Credentials:"
	field "Address:" "$client_addr"
	field "Private Key:" "$client_priv"
	field "Public Key:" "$client_pub"
	field "Preshared Key:" "$client_psk"
	field "Endpoint:" "${server_ip}:${server_port}"
	echo "AWG Params (2.0):"
	printf '  %s\n' "Jc=$Jc  Jmin=$Jmin  Jmax=$Jmax"
	printf '  %s\n' "S1=$S1  S2=$S2  S3=$S3  S4=$S4"
	printf '  %s\n' "H1=$H1  H2=$H2"
	printf '  %s\n' "H3=$H3  H4=$H4"
	section "Config:"
	printf '  %s\n' "$AWG_CLIENTS/${client_name}.conf"
}

_client_pubkey() {
	awk -v want="# $1" '
		$0 == want { inblock = 1; next }
		inblock && /^# / { exit }
		inblock && /^PublicKey/ { print $3; exit }
	' "$AWG_CONFIG"
}

_drop_peer_block() {
	local tmp
	tmp=$(mktemp)
	awk -v want="# $1" '
		$0 == want { skip = 1; next }
		skip && /^# / { skip = 0 }
		!skip { print }
	' "$AWG_CONFIG" | cat -s >"$tmp"
	cat "$tmp" >"$AWG_CONFIG"
	rm -f "$tmp"
}

svc_remove_client() {
	need_root

	local all=0 name=""
	while [ $# -gt 0 ]; do
		case "$1" in
		--all) all=1 ;;
		-*) usage "sdx vpn remove {<name>|--all}" ;;
		*) name="$1" ;;
		esac
		shift
	done

	[ -n "$name" ] || [ "$all" = 1 ] ||
		usage "sdx vpn remove {<name>|--all}"
	[ -f "$AWG_CONFIG" ] || die "not configured — run: install.sh"

	local -a targets=()
	if [ "$all" -eq 1 ]; then
		local f
		for f in "$AWG_CLIENTS"/*.conf; do
			[ -f "$f" ] || continue
			targets+=("$(basename "$f" .conf)")
		done
		[ "${#targets[@]}" -gt 0 ] || die "no clients to remove"
	else
		[ -f "$AWG_CLIENTS/${name}.conf" ] || die "client '$name' not found"
		targets=("$name")
	fi

	backup_file "$AWG_CONFIG"

	local c pub
	for c in "${targets[@]}"; do
		pub=$(_client_pubkey "$c")
		_drop_peer_block "$c"
		rm -f "$AWG_CLIENTS/${c}.conf"

		if [ -n "$pub" ] && ip link show "$AWG_IFACE" &>/dev/null; then
			awg set "$AWG_IFACE" peer "$pub" remove
			log_event "$LOG_FILE" "Removed client '$c' (hot-reload)"
		else
			log_event "$LOG_FILE" "Removed client '$c' (restart needed)"
		fi
		echo "removed $c"
	done
}

svc_export() {
	local name="" dir=""

	while [ $# -gt 0 ]; do
		case "$1" in
		-o | --output)
			[ $# -ge 2 ] || usage "sdx vpn export [<name>] [-o DIR]"
			dir="${2%/}"
			shift
			;;
		-*) usage "sdx vpn export [<name>] [-o DIR]" ;;
		*) name="$1" ;;
		esac
		shift
	done

	[ -d "$AWG_CLIENTS" ] || die "no clients — run: sdx vpn add"

	local -a clients=()
	local f
	for f in "$AWG_CLIENTS"/*.conf; do
		[ -f "$f" ] || continue
		clients+=("$(basename "$f" .conf)")
	done
	[ "${#clients[@]}" -gt 0 ] || die "no clients — run: sdx vpn add"

	if [ -z "$name" ]; then
		local first=1 c
		for c in "${clients[@]}"; do
			if [ -n "$dir" ]; then
				_write_client_config "$c" "$dir"
			else
				[ "$first" = 1 ] || echo
				echo "# $c"
				cat "$AWG_CLIENTS/${c}.conf"
				first=0
			fi
		done
		return
	fi

	local file="$AWG_CLIENTS/${name}.conf"
	[ -f "$file" ] || die "client '$name' not found"

	if [ -n "$dir" ]; then
		_write_client_config "$name" "$dir"
	else
		cat "$file"
	fi
}

_write_client_config() {
	local name="$1" dir="$2" path
	mkdir -p "$dir"
	path="$dir/$(config_basename "$name").conf"

	cp "$AWG_CLIENTS/${name}.conf" "$path"
	chmod 600 "$path"
	echo "$path"
}

svc_rotate() {
	need_root

	echo "Regenerating keys and AWG params..."

	local was_running=0
	if systemctl is-active --quiet "$SERVICE"; then
		was_running=1
	fi

	svc_stop >/dev/null

	if [ -f "$AWG_CONFIG" ]; then
		backup_file "$AWG_CONFIG"
		rm -f "$AWG_CONFIG"
		echo "Old config backed up"
	fi
	rm -f "$AWG_PARAMS" "$AWG_DIR/.next_client" "$AWG_DIR/.server_pubkey"
	rm -rf "$AWG_CLIENTS"

	_genconfig

	if [ "$was_running" -eq 1 ]; then
		echo
		svc_start
	fi

	echo
	echo "Done. Old clients invalidated. Create new ones:"
	echo "  sdx vpn add"
}

svc_help() {
	cat <<EOF
start	Start the service
stop	Stop the service
restart	Restart the service
config	Show connection credentials
export [name] [-o DIR]	Export client configs	Export client configs, one or all, to DIR
rotate	Regenerate credentials	Regenerate keys and params (breaks all clients)
add [<name>]	Add a client
remove {<name>|--all}	Revoke a client
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
	config) svc_config ;;
	export) svc_export "$@" ;;
	rotate) svc_rotate ;;
	add) svc_add_client "$@" ;;
	remove) svc_remove_client "$@" ;;
	*) return 127 ;;
	esac
}
