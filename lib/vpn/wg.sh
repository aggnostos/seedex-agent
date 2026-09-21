# shellcheck shell=bash
# shellcheck source=lib/wireguard.sh
. "$(dirname "${BASH_SOURCE[0]}")/../wireguard.sh"

vpn_wg_profile() {
	WG_TOOL="wg"
	WG_QUICK="wg-quick"
	WG_CONF_DIR="/etc/wireguard"
	WG_IFACE="wg0"
	WG_PORT="51820"
	WG_NET="10.66.68"
	WG_NET6="fd5e:ede1"
	WG_TITLE="WireGuard"
}

vpn_wg_install() {
	need_root
	export DEBIAN_FRONTEND=noninteractive
	if command -v wg >/dev/null 2>&1 && command -v wg-quick >/dev/null 2>&1; then
		echo "  wireguard-tools $(dpkg-query -W -f='${Version}' wireguard-tools 2>/dev/null) (current)"
	else
		apt-get install -y -qq wireguard-tools || die "cannot install wireguard-tools"
		echo "  wireguard-tools $(dpkg-query -W -f='${Version}' wireguard-tools 2>/dev/null) installed"
	fi
	modprobe wireguard 2>/dev/null || [ -d /sys/module/wireguard ] ||
		die "the wireguard kernel module is not available on this kernel"
}

wg_bind wg
