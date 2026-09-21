# shellcheck shell=bash
# shellcheck source=lib/wireguard.sh
. "$(dirname "${BASH_SOURCE[0]}")/../wireguard.sh"

AWG_PARAMS_FILE=".params"
AWG_MIN_BUILD="${SEEDEX_AWG_MIN_BUILD:-202608130141}"
AWG_PPA="ppa:amnezia/ppa"
AWG_PACKAGES="amneziawg amneziawg-dkms amneziawg-tools"
AWG_PPA_SUITE="${AWG_PPA_SUITE:-}"
AWG_I1_DOMAINS="yandex.ru vk.com mail.ru ok.ru dzen.ru avito.ru ozon.ru rutube.ru kinopoisk.ru gosuslugi.ru"

vpn_awg_profile() {
	WG_TOOL="awg"
	WG_QUICK="awg-quick"
	WG_CONF_DIR="/etc/amnezia/amneziawg"
	WG_IFACE="awg0"
	WG_PORT="51821"
	WG_NET="10.66.67"
	WG_NET6="fd5e:ede0"
	WG_TITLE="AmneziaWG"
}

_awg_pick() {
	local n
	n=$(_rand_between 1 $#)
	eval "printf '%s\\n' \"\${$n}\""
}

_awg_gen_i1() {
	local domain label qname="" ttl ip
	# shellcheck disable=SC2086
	domain=$(_awg_pick $AWG_I1_DOMAINS)
	for label in $(echo "$domain" | tr '.' ' '); do
		qname="${qname}$(printf '%02x' "${#label}")$(printf '%s' "$label" | od -An -tx1 | tr -d ' \n')"
	done
	ttl=$(printf '%08x' "$(_rand_between 60 3600)")
	ip=$(printf '%02x%02x%02x%02x' "$(_awg_pick 5 77 87 93 178 185 213)" \
		"$(_rand_between 1 254)" "$(_rand_between 1 254)" "$(_rand_between 1 254)")
	printf '<r 2><b 0x81800001000100000000%s0000010001c00c00010001%s0004%s>\n' "$qname" "$ttl" "$ip"
}

_awg_gen_params() {
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
		i1=$(_awg_gen_i1)
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

vpn_awg_migrate() {
	local dir="$WG_ROOT/awg" legacy="/etc/amnezia/amneziawg"
	[ -f "$legacy/.server_pubkey" ] || return 0
	[ ! -d "$dir" ] || return 0
	mkdir -p "$dir"
	chmod 700 "$dir"
	[ ! -f "$legacy/.awg_params" ] || mv "$legacy/.awg_params" "$dir/$AWG_PARAMS_FILE"
	[ ! -d "$legacy/clients" ] || mv "$legacy/clients" "$dir/clients"
	[ ! -f "$legacy/.next_client" ] || mv "$legacy/.next_client" "$dir/.next_client"
	mv "$legacy/.server_pubkey" "$dir/.server_pubkey"
	echo "  moved the AmneziaWG client state from $legacy to $dir"
}

vpn_awg_params_gen() {
	_awg_gen_params >"$WG_DIR/$AWG_PARAMS_FILE"
	chmod 600 "$WG_DIR/$AWG_PARAMS_FILE"
}

vpn_awg_params_reset() {
	rm -f "$WG_DIR/$AWG_PARAMS_FILE"
}

vpn_awg_params_load() {
	[ -f "$WG_DIR/$AWG_PARAMS_FILE" ] || die "AWG params missing — run: sdx vpn rotate awg"
	# shellcheck disable=SC1090
	. "$WG_DIR/$AWG_PARAMS_FILE"
	[ "${AWG_PARAMS_VERSION:-1}" = 2 ] || die "this server holds AmneziaWG 1.x parameters — reissue them: sdx vpn rotate awg"
}

# shellcheck disable=SC2154
vpn_awg_params_block() {
	printf 'Jc = %s\nJmin = %s\nJmax = %s\n' "$Jc" "$Jmin" "$Jmax"
	printf 'S1 = %s\nS2 = %s\nS3 = %s\nS4 = %s\n' "$S1" "$S2" "$S3" "$S4"
	printf 'H1 = %s\nH2 = %s\nH3 = %s\nH4 = %s\n' "$H1" "$H2" "$H3" "$H4"
	[ -n "$I1" ] || return 0
	printf 'I1 = %s\n' "$I1"
}

# shellcheck disable=SC2154
vpn_awg_params_print() {
	section "AWG Params (2.0):"
	printf '  %s\n' "Jc=$Jc  Jmin=$Jmin  Jmax=$Jmax"
	printf '  %s\n' "S1=$S1  S2=$S2  S3=$S3  S4=$S4"
	printf '  %s\n' "H1=$H1  H2=$H2"
	printf '  %s\n' "H3=$H3  H4=$H4"
}

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

vpn_awg_install() {
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
		_awg_check_module_reload
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
	_awg_check_module_reload
	echo "Installed: $(awg --version 2>/dev/null)"
}

_awg_check_module_reload() {
	[ -d /sys/module/amneziawg ] || return 0

	local on_disk loaded
	on_disk=$(modinfo -F srcversion amneziawg 2>/dev/null || true)
	loaded=$(cat /sys/module/amneziawg/srcversion 2>/dev/null || true)
	[ -n "$on_disk" ] && [ -n "$loaded" ] || return 0
	[ "$on_disk" != "$loaded" ] || return 0

	if ip link show "$WG_IFACE" >/dev/null 2>&1; then
		echo "  note: a newer kernel module is installed but $WG_IFACE is up," >&2
		echo "  so the old one is still resident. Load it with:" >&2
		echo "    sdx vpn stop awg && ./install.sh vpn && sdx vpn start awg" >&2
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
I1 = $(_awg_gen_i1)
EOF
	awg setconf "$dev" "$conf" >/dev/null 2>&1 && rc=0

	rm -f "$conf"
	ip link del "$dev" >/dev/null 2>&1
	return "$rc"
}

vpn_awg_maintain() {
	local installed build floor="$AWG_MIN_BUILD"
	installed=$(_pkg_installed amneziawg-dkms)
	[ -n "$installed" ] && [ -n "$floor" ] || return 0
	build=$(_awg_build "$installed")
	[ -n "$build" ] && [ "$build" -lt "$floor" ] || return 0
	warn "amneziawg-dkms $installed is older than the tested baseline ($floor);"
	warn "upgrade it with: sdx vpn stop awg && install.sh vpn && sdx vpn start awg"
}

wg_bind awg
