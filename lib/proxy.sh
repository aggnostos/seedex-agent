# shellcheck shell=bash

SVC_ACTIONS="start stop restart config export rotate add remove"

SING_BOX_VERSION="1.14.0"
SING_BOX_SHA256_amd64="2375de6999f4f56ab46b4fc5ddf26a6aba1d3e61a0f4e7ddec2f4690457d5f63"
SING_BOX_SHA256_arm64="04d9b40bc98dc55b6f509ce3292145c65478f65866bea64826ebb2f382385088"

BINARY="/usr/local/bin/sing-box"
CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="$CONFIG_DIR/config.json"
PROTO_DIR="$CONFIG_DIR/protocols"
CERT_FILE="$CONFIG_DIR/cert.pem"
KEY_FILE="$CONFIG_DIR/key.pem"

SERVICE="sing-box"
SERVICE_FILE="/etc/systemd/system/${SERVICE}.service"

LOG_DIR="/var/log/seedex-proxy"
LOG_FILE="$LOG_DIR/sing-box.log"

SEEDEX_SNI_POOL="${SEEDEX_SNI_POOL:-www.microsoft.com www.apple.com www.amazon.com dl.google.com www.bing.com www.icloud.com}"

_valid_sni() {
	case "$1" in
	"" | -* | .* | *. | *[!A-Za-z0-9.-]*) return 1 ;;
	*.*) return 0 ;;
	esac
	return 1
}

_pick_sni() {
	local exclude="${1:-}" candidates="" c n i
	for c in $SEEDEX_SNI_POOL; do
		[ "$c" = "$exclude" ] && continue
		candidates="$candidates $c"
	done
	# shellcheck disable=SC2086
	set -- $candidates
	# shellcheck disable=SC2086
	[ $# -gt 0 ] || set -- $SEEDEX_SNI_POOL
	n=$#
	[ "$n" -gt 0 ] || die "SEEDEX_SNI_POOL is empty"
	i=$(_rand_between 1 "$n")
	eval "echo \"\${$i}\""
}

_gen_uuid() { cat /proc/sys/kernel/random/uuid; }
_gen_ss_key() { head -c 32 /dev/urandom | base64; }
_gen_hex() { head -c $(($1 / 2)) /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c "$1"; }
_gen_password() { head -c 24 /dev/urandom | base64 | tr '+/' '-_' | tr -d '='; }
_gen_short_id() { _gen_hex 8; }

_install_packages() {
	need_root

	if [ -x "$BINARY" ] && $BINARY version 2>/dev/null | grep -q "$SING_BOX_VERSION"; then
		echo "sing-box v${SING_BOX_VERSION} already installed"
		return
	fi

	local arch arch_name
	arch=$(uname -m)
	case "$arch" in
	x86_64) arch_name="amd64" ;;
	aarch64) arch_name="arm64" ;;
	*) die "unsupported architecture: $arch" ;;
	esac

	local want got
	eval "want=\${SING_BOX_SHA256_${arch_name}:-}"
	[ -n "$want" ] || die "no pinned SHA256 for sing-box ${SING_BOX_VERSION} (${arch_name})
refusing to install an unverified binary; set SING_BOX_SHA256_${arch_name} in lib/proxy.sh"

	echo "Downloading sing-box v${SING_BOX_VERSION} (${arch_name})..."
	wget -q "https://github.com/SagerNet/sing-box/releases/download/v${SING_BOX_VERSION}/sing-box-${SING_BOX_VERSION}-linux-${arch_name}.tar.gz" -O /tmp/sing-box.tar.gz || {
		rm -f /tmp/sing-box.tar.gz
		die "cannot download sing-box v${SING_BOX_VERSION} — check outbound access to github.com"
	}

	got=$(sha256sum /tmp/sing-box.tar.gz | awk '{print $1}')
	if [ "$got" != "$want" ]; then
		rm -f /tmp/sing-box.tar.gz
		die "sing-box tarball does not match the pinned checksum
  expected $want
  got      $got"
	fi

	tar xzf /tmp/sing-box.tar.gz -C /tmp
	install -m 0755 "/tmp/sing-box-${SING_BOX_VERSION}-linux-${arch_name}/sing-box" "$BINARY.new"
	mv -f "$BINARY.new" "$BINARY"
	rm -rf /tmp/sing-box.tar.gz "/tmp/sing-box-${SING_BOX_VERSION}-linux-${arch_name}"

	echo "Installed: $($BINARY version | head -1)"
}

svc_upgrade() {
	local had=0
	[ -x "$BINARY" ] && $BINARY version 2>/dev/null | grep -q "$SING_BOX_VERSION" && had=1
	_install_packages
	[ "$had" = 0 ] || return 0
	systemctl is-active --quiet "$SERVICE" 2>/dev/null || return 0
	$BINARY check -c "$CONFIG_FILE" ||
		die "the running config fails 'sing-box check' with v${SING_BOX_VERSION} — sing-box left running on the old binary until restarted"
	systemctl restart "$SERVICE"
	echo "sing-box restarted on v${SING_BOX_VERSION}"
}

PROXY_PROTOCOLS="vless trojan shadowsocks shadowtls vmess hysteria2 tuic anytls"
SS_METHOD="2022-blake3-aes-256-gcm"

_proto_supported() {
	case " $PROXY_PROTOCOLS " in
	*" $1 "*) return 0 ;;
	esac
	return 1
}

_proto_transport() {
	case "$1" in
	hysteria2 | tuic) echo udp ;;
	shadowsocks) echo "tcp udp" ;;
	*) echo tcp ;;
	esac
}

_proto_needs_cert() {
	case "$1" in
	trojan | vmess | hysteria2 | tuic | anytls) return 0 ;;
	esac
	return 1
}

_proto_file() { printf '%s/%s.json\n' "$PROTO_DIR" "$1"; }

_proto_configured() { [ -f "$(_proto_file "$1")" ]; }

_proto_list() {
	local f
	for f in "$PROTO_DIR"/*.json; do
		[ -f "$f" ] || continue
		f="${f##*/}"
		echo "${f%.json}"
	done
}

_proto_get() { jq -r --arg k "$2" '.[$k] // empty' "$(_proto_file "$1")"; }

_proto_port_specs() {
	local p t
	for p in $(_proto_list); do
		for t in $(_proto_transport "$p"); do
			printf '%s/%s:seedex-proxy-%s\n' "$(_proto_get "$p" port)" "$t" "$p"
		done
	done
}

_port_used_by_host() {
	local lib="${SEEDEX_LIB:-/usr/local/lib/seedex}" p
	{
		for p in $(ssh_ports); do
			echo "$p/tcp:SSH"
		done
		# shellcheck disable=SC1090,SC1091
		(
			. "$lib/vpn.sh"
			_vpn_port_specs
		)
		# shellcheck disable=SC1090,SC1091
		(
			. "$lib/link.sh"
			echo "$LINK_PORT/tcp:seedex-link"
		)
	} | awk -F: -v s="$1" '$1 == s && !found { print $2; found = 1 } END { exit !found }'
}

_port_taken_by() {
	local p
	for p in $(_proto_list); do
		[ "$p" = "$2" ] && continue
		[ "$(_proto_get "$p" port)" = "$1" ] && echo "$p" && return 0
	done
	return 1
}

_ensure_cert() {
	[ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ] && return 0
	local sni
	sni="${SEEDEX_TLS_SNI:-$(_pick_sni)}"
	_valid_sni "$sni" || die "not a valid SNI hostname: '$sni'"
	openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
		-keyout "$KEY_FILE" -out "$CERT_FILE" \
		-days 3650 -nodes -subj "/CN=${sni}" \
		-addext "subjectAltName=DNS:${sni}" 2>/dev/null
	chmod 600 "$KEY_FILE"
	echo "  Certificate generated for $sni (pin the name with SEEDEX_TLS_SNI)"
}

_cert_sni() {
	openssl x509 -in "$CERT_FILE" -noout -subject 2>/dev/null | sed -n 's/.*CN *= *\([^,/]*\).*/\1/p'
}

_server_cert() {
	[ -f "$CERT_FILE" ] || die "server certificate not found at $CERT_FILE"
	cat "$CERT_FILE"
}

_gen_proto() {
	local proto="$1" port="$2" sni keypair
	case "$proto" in
	vless)
		keypair=$($BINARY generate reality-keypair)
		sni="${SEEDEX_REALITY_SNI:-$(_pick_sni)}"
		_valid_sni "$sni" || die "not a valid SNI hostname: '$sni'"
		jq -n --argjson port "$port" --arg uuid "$(_gen_uuid)" --arg sni "$sni" \
			--arg priv "$(echo "$keypair" | grep -i private | awk '{print $NF}')" \
			--arg pub "$(echo "$keypair" | grep -i public | awk '{print $NF}')" \
			--arg sid "$(_gen_short_id)" \
			'{port: $port, uuid: $uuid, sni: $sni, private_key: $priv, public_key: $pub, short_id: $sid}'
		;;
	shadowtls)
		sni="${SEEDEX_SHADOWTLS_SNI:-$(_pick_sni)}"
		_valid_sni "$sni" || die "not a valid SNI hostname: '$sni'"
		jq -n --argjson port "$port" --arg pw "$(_gen_password)" --arg sni "$sni" \
			--arg method "$SS_METHOD" --arg sspw "$(_gen_ss_key)" \
			'{port: $port, password: $pw, sni: $sni, ss_method: $method, ss_password: $sspw}'
		;;
	shadowsocks)
		jq -n --argjson port "$port" --arg method "$SS_METHOD" --arg pw "$(_gen_ss_key)" \
			'{port: $port, method: $method, password: $pw}'
		;;
	vmess)
		jq -n --argjson port "$port" --arg uuid "$(_gen_uuid)" '{port: $port, uuid: $uuid}'
		;;
	tuic)
		jq -n --argjson port "$port" --arg uuid "$(_gen_uuid)" --arg pw "$(_gen_password)" \
			'{port: $port, uuid: $uuid, password: $pw}'
		;;
	trojan | hysteria2 | anytls)
		jq -n --argjson port "$port" --arg pw "$(_gen_password)" '{port: $port, password: $pw}'
		;;
	*) die "unsupported protocol: $proto" ;;
	esac
}

_inbound() {
	local proto="$1" f
	f=$(_proto_file "$proto")
	case "$proto" in
	vless)
		jq '[{ type: "vless", tag: "vless-in", listen: "::", listen_port: .port,
		       users: [{ uuid: .uuid, flow: "xtls-rprx-vision" }],
		       tls: { enabled: true, server_name: .sni,
		              reality: { enabled: true, handshake: { server: .sni, server_port: 443 },
		                         private_key: .private_key, short_id: [.short_id] } } }]' "$f"
		;;
	shadowtls)
		jq '[{ type: "shadowtls", tag: "shadowtls-in", listen: "::", listen_port: .port, version: 3,
		       users: [{ password: .password }],
		       handshake: { server: .sni, server_port: 443 }, strict_mode: true, detour: "shadowtls-ss-in" },
		     { type: "shadowsocks", tag: "shadowtls-ss-in", listen: "127.0.0.1",
		       method: .ss_method, password: .ss_password }]' "$f"
		;;
	shadowsocks)
		jq '[{ type: "shadowsocks", tag: "shadowsocks-in", listen: "::", listen_port: .port,
		       method: .method, password: .password }]' "$f"
		;;
	trojan)
		jq --arg c "$CERT_FILE" --arg k "$KEY_FILE" \
			'[{ type: "trojan", tag: "trojan-in", listen: "::", listen_port: .port,
			    users: [{ password: .password }],
			    tls: { enabled: true, certificate_path: $c, key_path: $k } }]' "$f"
		;;
	vmess)
		jq --arg c "$CERT_FILE" --arg k "$KEY_FILE" \
			'[{ type: "vmess", tag: "vmess-in", listen: "::", listen_port: .port,
			    users: [{ uuid: .uuid }],
			    tls: { enabled: true, certificate_path: $c, key_path: $k } }]' "$f"
		;;
	hysteria2)
		jq --arg c "$CERT_FILE" --arg k "$KEY_FILE" \
			'[{ type: "hysteria2", tag: "hysteria2-in", listen: "::", listen_port: .port,
			    users: [{ password: .password }],
			    tls: { enabled: true, certificate_path: $c, key_path: $k } }]' "$f"
		;;
	tuic)
		jq --arg c "$CERT_FILE" --arg k "$KEY_FILE" \
			'[{ type: "tuic", tag: "tuic-in", listen: "::", listen_port: .port,
			    users: [{ uuid: .uuid, password: .password }], congestion_control: "bbr",
			    tls: { enabled: true, alpn: ["h3"], certificate_path: $c, key_path: $k } }]' "$f"
		;;
	anytls)
		jq --arg c "$CERT_FILE" --arg k "$KEY_FILE" \
			'[{ type: "anytls", tag: "anytls-in", listen: "::", listen_port: .port,
			    users: [{ password: .password }],
			    tls: { enabled: true, certificate_path: $c, key_path: $k } }]' "$f"
		;;
	esac
}

_outbounds() {
	local proto="$1" f cert="" sni=""
	f=$(_proto_file "$proto")
	if _proto_needs_cert "$proto"; then
		cert=$(_server_cert) || return 1
		sni=$(_cert_sni)
	fi
	case "$proto" in
	vless)
		jq --arg s "$SERVER_IP" '[{ type: "vless", tag: "vless", server: $s, server_port: .port,
			uuid: .uuid, flow: "xtls-rprx-vision", packet_encoding: "xudp",
			tls: { enabled: true, server_name: .sni, utls: { enabled: true, fingerprint: "chrome" },
			       reality: { enabled: true, public_key: .public_key, short_id: .short_id } } }]' "$f"
		;;
	shadowtls)
		jq --arg s "$SERVER_IP" '[{ type: "shadowtls", tag: "shadowtls-transport", server: $s, server_port: .port,
			version: 3, password: .password, tls: { enabled: true, server_name: .sni } },
		  { type: "shadowsocks", tag: "shadowtls", server: $s, server_port: .port,
			method: .ss_method, password: .ss_password, detour: "shadowtls-transport",
			multiplex: { enabled: false } }]' "$f"
		;;
	shadowsocks)
		jq --arg s "$SERVER_IP" '[{ type: "shadowsocks", tag: "shadowsocks", server: $s, server_port: .port,
			method: .method, password: .password }]' "$f"
		;;
	trojan)
		jq --arg s "$SERVER_IP" --arg sni "$sni" --arg cert "$cert" '[{ type: "trojan", tag: "trojan",
			server: $s, server_port: .port, password: .password,
			tls: { enabled: true, server_name: $sni, certificate: ($cert | split("\n") | map(select(length > 0))) } }]' "$f"
		;;
	vmess)
		jq --arg s "$SERVER_IP" --arg sni "$sni" --arg cert "$cert" '[{ type: "vmess", tag: "vmess",
			server: $s, server_port: .port, uuid: .uuid, security: "auto",
			tls: { enabled: true, server_name: $sni, certificate: ($cert | split("\n") | map(select(length > 0))) } }]' "$f"
		;;
	hysteria2)
		jq --arg s "$SERVER_IP" --arg sni "$sni" --arg cert "$cert" '[{ type: "hysteria2", tag: "hysteria2",
			server: $s, server_port: .port, password: .password,
			tls: { enabled: true, server_name: $sni, certificate: ($cert | split("\n") | map(select(length > 0))) } }]' "$f"
		;;
	tuic)
		jq --arg s "$SERVER_IP" --arg sni "$sni" --arg cert "$cert" '[{ type: "tuic", tag: "tuic",
			server: $s, server_port: .port, uuid: .uuid, password: .password, congestion_control: "bbr",
			tls: { enabled: true, server_name: $sni, alpn: ["h3"], certificate: ($cert | split("\n") | map(select(length > 0))) } }]' "$f"
		;;
	anytls)
		jq --arg s "$SERVER_IP" --arg sni "$sni" --arg cert "$cert" '[{ type: "anytls", tag: "anytls",
			server: $s, server_port: .port, password: .password,
			idle_session_check_interval: "30s", idle_session_timeout: "30s", min_idle_session: 1,
			tls: { enabled: true, server_name: $sni, certificate: ($cert | split("\n") | map(select(length > 0))) } }]' "$f"
		;;
	esac
}

_render_config() {
	local p inbounds='[]' tmp
	for p in $(_proto_list); do
		inbounds=$(jq -n --argjson a "$inbounds" --argjson b "$(_inbound "$p")" '$a + $b')
	done
	tmp=$(mktemp)
	jq -n --arg log "$LOG_FILE" --argjson inbounds "$inbounds" '{
		log: { level: "info", timestamp: true, output: $log },
		inbounds: $inbounds,
		outbounds: [{ type: "direct", tag: "direct" }]
	}' >"$tmp"
	if [ -x "$BINARY" ] && ! $BINARY check -c "$tmp" 2>/dev/null; then
		rm -f "$tmp"
		die "rendered config fails 'sing-box check' — nothing was changed"
	fi
	mv "$tmp" "$CONFIG_FILE"
	chmod 600 "$CONFIG_FILE"
}

_apply() {
	_render_config
	if systemctl is-active --quiet "$SERVICE"; then
		systemctl restart "$SERVICE"
		_still_running
		echo "  Restarted"
	elif systemctl is-enabled --quiet "$SERVICE" 2>/dev/null; then
		systemctl start "$SERVICE"
		_still_running
		echo "  Started"
	fi
}

_still_running() {
	sleep 2
	systemctl is-active --quiet "$SERVICE" && return 0
	journalctl -u "$SERVICE" -n 5 --no-pager -o cat >&2 2>/dev/null
	if [ -n "${APPLY_UNDO:-}" ]; then
		rm -f "$(_proto_file "$APPLY_UNDO")"
		firewall_delete "seedex-proxy-$APPLY_UNDO"
		if [ -n "$(_proto_list)" ]; then
			_render_config
			systemctl restart "$SERVICE"
		else
			systemctl stop "$SERVICE"
		fi
		die "sing-box cannot start with $APPLY_UNDO, so $APPLY_UNDO is removed again — see: journalctl -u $SERVICE"
	fi
	die "sing-box stopped right after the start — see: journalctl -u $SERVICE"
}

_need_server_ip() {
	[ -n "$SERVER_IP" ] || SERVER_IP=$(need_ip) || exit 1
}

_render_client_config() {
	local protocol="$1" outbounds
	_need_server_ip
	outbounds=$(_outbounds "$protocol") ||
		die "cannot render outbounds for $protocol"

	local server_cidrs='[]'
	case "$SERVER_IP" in
	"" | *[!0-9.]*) ;;
	*) server_cidrs="[\"${SERVER_IP}/32\"]" ;;
	esac

	jq -n --argjson outbounds "$outbounds" \
		--argjson cidrs "$server_cidrs" \
		--arg tag "$protocol" '
		{
		  log: { level: "warn", timestamp: true },
		  dns: {
		    servers: [
		      { type: "https", tag: "remote-dns", server: "1.1.1.1",
		        path: "/dns-query", domain_resolver: "local-dns", detour: $tag },
		      { type: "udp", tag: "local-dns", server: "1.0.0.1" }
		    ],
		    final: "remote-dns",
		    strategy: "ipv4_only"
		  },
		  inbounds: [
		    { type: "tun", tag: "tun-in", interface_name: "proxy0",
		      address: ["172.19.0.1/30"], auto_route: false, stack: "gvisor" }
		  ],
		  outbounds: ($outbounds + [{ type: "direct", tag: "direct" }]),
		  route: {
		    rules: [
		      { inbound: "tun-in", action: "sniff" },
		      { protocol: "dns", action: "hijack-dns" },
		      { ip_is_private: true, outbound: "direct" },
		      { ip_cidr: ($cidrs + ["1.0.0.1/32"]), outbound: "direct" }
		    ],
		    final: $tag,
		    auto_detect_interface: true,
		    default_domain_resolver: "local-dns"
		  }
		}'
}

_uri_enc() { jq -rn --arg s "$1" '$s | @uri'; }

_render_link() {
	local protocol="$1" f tag sni
	_need_server_ip
	f=$(_proto_file "$protocol")
	tag=$(_uri_enc "$(config_basename "$protocol")")
	! _proto_needs_cert "$protocol" || sni=$(_cert_sni)
	case "$protocol" in
	vless)
		printf 'vless://%s@%s:%s?security=reality&encryption=none&pbk=%s&sid=%s&sni=%s&fp=chrome&flow=xtls-rprx-vision&type=tcp#%s\n' \
			"$(jq -r .uuid "$f")" "$SERVER_IP" "$(jq -r .port "$f")" \
			"$(_uri_enc "$(jq -r .public_key "$f")")" "$(jq -r .short_id "$f")" "$(jq -r .sni "$f")" "$tag"
		;;
	shadowsocks)
		printf 'ss://%s@%s:%s#%s\n' \
			"$(jq -r '"\(.method):\(.password)"' "$f" | tr -d '\n' | base64 -w0 | tr '+/' '-_' | tr -d '=')" \
			"$SERVER_IP" "$(jq -r .port "$f")" "$tag"
		;;
	trojan)
		printf 'trojan://%s@%s:%s?security=tls&sni=%s&allowInsecure=1&type=tcp#%s\n' \
			"$(_uri_enc "$(jq -r .password "$f")")" "$SERVER_IP" "$(jq -r .port "$f")" "$sni" "$tag"
		;;
	vmess)
		printf 'vmess://%s\n' "$(jq -c --arg ip "$SERVER_IP" --arg sni "$sni" --arg ps "$(config_basename "$protocol")" \
			'{v: "2", ps: $ps, add: $ip, port: (.port | tostring), id: .uuid, aid: "0", scy: "auto",
			  net: "tcp", type: "none", host: "", path: "", tls: "tls", sni: $sni, allowInsecure: true}' "$f" |
			tr -d '\n' | base64 -w0)"
		;;
	hysteria2)
		printf 'hysteria2://%s@%s:%s?sni=%s&insecure=1#%s\n' \
			"$(_uri_enc "$(jq -r .password "$f")")" "$SERVER_IP" "$(jq -r .port "$f")" "$sni" "$tag"
		;;
	tuic)
		printf 'tuic://%s:%s@%s:%s?sni=%s&alpn=h3&congestion_control=bbr&udp_relay_mode=native&allow_insecure=1#%s\n' \
			"$(jq -r .uuid "$f")" "$(_uri_enc "$(jq -r .password "$f")")" "$SERVER_IP" "$(jq -r .port "$f")" "$sni" "$tag"
		;;
	anytls)
		printf 'anytls://%s@%s:%s?sni=%s&insecure=1#%s\n' \
			"$(_uri_enc "$(jq -r .password "$f")")" "$SERVER_IP" "$(jq -r .port "$f")" "$sni" "$tag"
		;;
	shadowtls)
		die "shadowtls has no share-link format — use the JSON export"
		;;
	esac
}

_write_client_config() {
	local protocol="$1" dir="$2" path
	mkdir -p "$dir"
	path="$dir/$(config_basename "$protocol").json"
	_render_client_config "$protocol" >"$path"
	chmod 600 "$path"
	echo "$path"
}

_print_proto() {
	local p="$1" port
	port=$(_proto_get "$p" port)
	section "$p ($port/$(_proto_transport "$p" | tr ' ' '+')):"
	case "$p" in
	vless)
		field "UUID:" "$(_proto_get "$p" uuid)"
		field "Public Key:" "$(_proto_get "$p" public_key)"
		field "Short ID:" "$(_proto_get "$p" short_id)"
		field "SNI:" "$(_proto_get "$p" sni)"
		;;
	shadowtls)
		field "Password:" "$(_proto_get "$p" password)"
		field "SNI:" "$(_proto_get "$p" sni)"
		field "SS Method:" "$(_proto_get "$p" ss_method)"
		field "SS Password:" "$(_proto_get "$p" ss_password)"
		;;
	shadowsocks)
		field "Method:" "$(_proto_get "$p" method)"
		field "Password:" "$(_proto_get "$p" password)"
		;;
	vmess) field "UUID:" "$(_proto_get "$p" uuid)" ;;
	tuic)
		field "UUID:" "$(_proto_get "$p" uuid)"
		field "Password:" "$(_proto_get "$p" password)"
		;;
	*) field "Password:" "$(_proto_get "$p" password)" ;;
	esac
	if _proto_needs_cert "$p"; then
		field "SNI:" "$(_cert_sni)"
	fi
}

svc_add() {
	need_root
	need_cmd jq
	need_cmd openssl
	local proto="${1:-}" port="${2:-}" other t
	[ -n "$proto" ] && [ -n "$port" ] || usage "sdx proxy add <protocol> <port>"
	_proto_supported "$proto" || die "unsupported protocol: $proto
supported: $PROXY_PROTOCOLS"
	case "$port" in
	*[!0-9]*) die "port must be a number: $port" ;;
	esac
	[ "$port" -ge 1 ] && [ "$port" -le 65535 ] || die "port out of range: $port"
	[ -x "$BINARY" ] && [ -f "$SERVICE_FILE" ] || svc_provision >/dev/null
	_proto_configured "$proto" && die "$proto is already configured on port $(_proto_get "$proto" port)
remove it first, or rotate its credentials with: sdx proxy rotate $proto"
	other=$(_port_taken_by "$port" "$proto") && die "port $port is already used by $other"
	for t in $(_proto_transport "$proto"); do
		other=$(_port_used_by_host "$port/$t") && die "port $port/$t is already used by $other"
	done

	mkdir -p "$PROTO_DIR"
	chmod 700 "$PROTO_DIR"
	! _proto_needs_cert "$proto" || _ensure_cert
	_gen_proto "$proto" "$port" >"$(_proto_file "$proto")"
	chmod 600 "$(_proto_file "$proto")"
	echo "Added $proto on port $port"

	local spec
	for spec in $(_proto_port_specs | grep "^${port}/"); do
		firewall_allow "$spec"
	done
	echo "  Firewall: allowed $port/$(_proto_transport "$proto" | tr ' ' '+')"

	APPLY_UNDO="$proto"
	_apply
	APPLY_UNDO=""
	echo
	_print_proto "$proto"
	echo
	echo "Client config: sdx proxy export $proto -o DIR"
}

svc_remove() {
	need_root
	local proto="${1:-}" port
	[ -n "$proto" ] || usage "sdx proxy remove <protocol>"
	_proto_configured "$proto" || die "$proto is not configured"
	port=$(_proto_get "$proto" port)

	firewall_delete "seedex-proxy-$proto"
	rm -f "$(_proto_file "$proto")"
	echo "Removed $proto (port $port closed)"
	_apply
}

svc_rotate() {
	need_root
	need_cmd jq
	local proto="${1:-}" p port
	if [ -n "$proto" ]; then
		_proto_configured "$proto" || die "$proto is not configured"
		set -- "$proto"
	else
		# shellcheck disable=SC2046
		set -- $(_proto_list)
		[ $# -gt 0 ] || die "no protocols configured — add one with: sdx proxy add <protocol> <port>"
	fi
	for p in "$@"; do
		port=$(_proto_get "$p" port)
		backup_file "$(_proto_file "$p")"
		_gen_proto "$p" "$port" >"$(_proto_file "$p")"
		chmod 600 "$(_proto_file "$p")"
		echo "Rotated $p (port $port kept)"
	done
	_apply
	echo
	for p in "$@"; do _print_proto "$p"; done
	echo
	echo "Every client of the rotated protocol(s) must re-import its config."
}

svc_export() {
	local protocol="" dir="" link=0 b64=0
	while [ $# -gt 0 ]; do
		case "$1" in
		-o | --output)
			[ $# -ge 2 ] || usage "sdx proxy export [<protocol>] [-o DIR | --link [--base64]]"
			dir="${2%/}"
			shift
			;;
		--link) link=1 ;;
		--base64) b64=1 ;;
		-*) usage "sdx proxy export [<protocol>] [-o DIR | --link [--base64]]" ;;
		*) protocol="$1" ;;
		esac
		shift
	done
	[ "$link" = 0 ] || [ -z "$dir" ] || usage "sdx proxy export [<protocol>] [-o DIR | --link [--base64]]"
	[ "$b64" = 0 ] || [ "$link" = 1 ] || usage "sdx proxy export [<protocol>] --link --base64"
	need_cmd jq
	SERVER_IP=""

	if [ -n "$protocol" ]; then
		_proto_configured "$protocol" || die "$protocol is not configured on this server"
		set -- "$protocol"
	else
		# shellcheck disable=SC2046
		set -- $(_proto_list)
		[ $# -gt 0 ] || die "no protocols configured — add one with: sdx proxy add <protocol> <port>"
	fi

	local p first=1 skipped="" body=""
	for p in "$@"; do
		if [ "$link" = 1 ]; then
			if [ "$p" = shadowtls ] && [ $# -gt 1 ]; then
				skipped="${skipped:+$skipped }$p"
				continue
			fi
			if [ "$b64" = 1 ]; then
				body="${body}$(_render_link "$p")
"
			else
				_render_link "$p"
			fi
		elif [ -n "$dir" ]; then
			_write_client_config "$p" "$dir"
		else
			[ "$first" = 1 ] || echo
			[ $# -eq 1 ] || echo "# $p"
			_render_client_config "$p"
			first=0
		fi
	done
	[ -z "$body" ] || printf '%s\n' "$(printf '%s' "$body" | base64 -w0)"
	[ -z "$skipped" ] || warn "skipped: $skipped — no share-link format, use the JSON export"
}

svc_config() {
	need_cmd jq
	SERVER_IP=""
	_need_server_ip
	section "Server:"
	printf '  %s\n' "$SERVER_IP"
	local p n=0
	for p in $(_proto_list); do
		_print_proto "$p"
		n=$((n + 1))
	done
	[ "$n" -gt 0 ] || printf '  %s\n' "no protocols configured"
}

svc_provision() {
	need_root

	echo "[1/5] Checking sing-box..."
	_install_packages

	echo "[2/5] Setting up directories..."
	mkdir -p "$LOG_DIR" "$PROTO_DIR"
	chmod 700 "$PROTO_DIR"
	echo "  $LOG_DIR"
	echo "  $PROTO_DIR"

	echo "[3/5] Rendering configuration..."
	if [ -f "$CONFIG_FILE" ]; then
		echo "  Config already exists — keeping it"
	else
		need_cmd jq
		_render_config
		echo "  $CONFIG_FILE (no protocols yet)"
	fi

	echo "[4/5] Installing service..."
	_install_service
	echo "  Service installed and enabled (starts on boot)"

	echo "[5/5] Configuring firewall and logrotate..."
	# shellcheck disable=SC2046
	firewall_apply $(_proto_port_specs)
	echo "  Firewall configured"

	logrotate_install seedex-proxy "$LOG_FILE"
	echo "  Logrotate configured"

	echo
	[ -n "$(_proto_list)" ] || echo "No protocols yet — add one with: sdx proxy add <protocol> <port>"
}

_install_service() {
	cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=sing-box proxy server
After=network.target

[Service]
Type=simple
ExecStart=$BINARY run -c $CONFIG_FILE
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
	systemctl daemon-reload
	systemctl enable "$SERVICE" >/dev/null 2>&1
}

svc_start() {
	need_root
	if [ -z "$(_proto_list)" ]; then
		echo "no protocols configured — add one with: sdx proxy add <protocol> <port>"
		return
	fi
	if systemctl is-active --quiet "$SERVICE"; then
		echo "Already running"
		return
	fi
	systemctl start "$SERVICE"
	echo "Started"
}

svc_stop() {
	need_root
	if ! systemctl is-active --quiet "$SERVICE"; then
		echo "Not running"
		return
	fi
	systemctl stop "$SERVICE"
	echo "Stopped"
}

svc_restart() {
	need_root
	if [ -z "$(_proto_list)" ]; then
		echo "no protocols configured — add one with: sdx proxy add <protocol> <port>"
		return
	fi
	systemctl restart "$SERVICE"
	echo "Restarted"
}

svc_status() {
	local up=0
	systemctl is-active --quiet "$SERVICE" && up=1
	status_header "Proxy" "$up"
	if [ -f "$CONFIG_FILE" ] && [ -x "$BINARY" ] && ! $BINARY check -c "$CONFIG_FILE" &>/dev/null; then
		field "Config:" "INVALID — see: /var/log/seedex-proxy/sing-box.log"
	fi
	local p n=0
	for p in $(_proto_list); do
		[ "$n" -gt 0 ] || echo "  Protocols:"
		printf '    %-14s %s/%s\n' "$p" "$(_proto_get "$p" port)" "$(_proto_transport "$p" | tr ' ' '+')"
		n=$((n + 1))
	done
	[ "$n" -gt 0 ] || field "Protocols:" "none — add one with: sdx proxy add <protocol> <port>"
}

svc_help() {
	cat <<EOF
start	Start the service
stop	Stop the service
restart	Restart the service
config	Show connection credentials
add <protocol> <port>	Add a protocol	Add a protocol on a port and open it: $PROXY_PROTOCOLS
remove <protocol>	Remove a protocol	Remove a protocol and close its port
export [protocol] [-o DIR | --link [--base64]]	Export client configs	Export client configs, one protocol or all, to DIR; --link prints share links (TLS ones with insecure=1), --base64 encodes them as a subscription
rotate [protocol]	Regenerate credentials	Regenerate credentials of one protocol or all, keeping ports
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
	add) svc_add "$@" ;;
	remove) svc_remove "$@" ;;
	export) svc_export "$@" ;;
	rotate) svc_rotate "$@" ;;
	*) return 127 ;;
	esac
}
