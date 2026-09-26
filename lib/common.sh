#!/bin/bash

[ -n "${SEEDEX_COMMON_SH:-}" ] && return 0
SEEDEX_COMMON_SH=1

SEEDEX_VERSION="$(cat "${SEEDEX_LIB:-/usr/local/lib/seedex}/version" 2>/dev/null || echo unknown)"
readonly SEEDEX_VERSION

die() {
	printf '%s: %s\n' "${0##*/}" "$*" >&2
	exit 1
}

warn() {
	printf '%s: %s\n' "${0##*/}" "$*" >&2
}

usage() {
	printf 'usage: %s\n' "$*" >&2
	exit 2
}

need_root() {
	[ "$(id -u)" -eq 0 ] || die "must be run as root"
}

need_cmd() {
	command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

section() {
	printf '%s\n' "$1"
}

field() {
	printf '  %-15s %s\n' "$1" "$2"
}

mark() {
	[ "$1" = 1 ] && printf '[*]' || printf '[ ]'
}

status_header() {
	printf '%s %s:\n' "$(mark "$([ "$2" = 1 ] && echo 1 || echo 0)")" "$1"
}

indent() {
	sed 's/^/  /'
}

log_event() {
	local file="$1"
	shift
	mkdir -p "$(dirname "$file")"
	printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$file"
}

logrotate_install() {
	local name="$1" file="$2"
	cat >"/etc/logrotate.d/$name" <<EOF
$file {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF
}

_SEEDEX_IP=""
SEEDEX_BACKUP_KEEP="${SEEDEX_BACKUP_KEEP:-3}"

backup_file() {
	local src="$1" keep="$SEEDEX_BACKUP_KEEP" dst stale
	[ -f "$src" ] || return 0

	dst="${src}.bak.$(date +%s)"
	cp "$src" "$dst" || return 1
	chmod 600 "$dst"

	stale=$(for f in "${src}".bak.*; do [ -f "$f" ] && printf '%s\n' "$f"; done | sort -r | tail -n +$((keep + 1)))
	[ -n "$stale" ] || return 0
	printf '%s\n' "$stale" | while IFS= read -r f; do
		[ -n "$f" ] && rm -f "$f"
	done
	return 0
}

_rand_between() {
	local min="$1" max="$2"
	local span=$((max - min + 1))
	[ "$span" -gt 0 ] || die "_rand_between: empty range ${min}..${max}"
	[ "$span" -le 4294967296 ] || die "_rand_between: range ${min}..${max} exceeds 32 bits"

	local limit=$((4294967296 / span * span)) v
	while :; do
		v=$(od -An -N4 -tu4 </dev/urandom | tr -d ' \n')
		[ -n "$v" ] || die "_rand_between: cannot read /dev/urandom"
		[ "$v" -lt "$limit" ] && break
	done
	echo $((v % span + min))
}

get_ip() {
	[ -n "$_SEEDEX_IP" ] || _SEEDEX_IP="${SEEDEX_SERVER_IP:-}"
	[ -n "$_SEEDEX_IP" ] || {
		local url reply
		for url in https://ifconfig.me https://icanhazip.com; do
			reply=$(curl -fsS -4 --max-time 3 "$url" 2>/dev/null) || continue
			reply=$(printf '%s' "$reply" | tr -d '[:space:]')
			case "$reply" in
			"" | *[!0-9.]*) continue ;;
			esac
			_SEEDEX_IP="$reply"
			break
		done
	}
	[ -n "$_SEEDEX_IP" ] || return 1
	printf '%s\n' "$_SEEDEX_IP"
}

need_ip() {
	get_ip || die "cannot tell this server's public IPv4 address — set it with SEEDEX_SERVER_IP=<address>"
}

server_name() {
	local h
	h=$(hostname -s 2>/dev/null || hostname 2>/dev/null)
	h=${h%%.*}
	[ -n "$h" ] && [ "$h" != localhost ] || h=server
	printf '%s\n' "$h" | tr -c 'A-Za-z0-9-\n' '-'
}

config_basename() {
	printf '%s-%s\n' "$(server_name)" "$1"
}

firewall_ensure() {
	command -v ufw >/dev/null 2>&1 && return 0
	apt-get update -qq
	apt-get install -y -qq ufw || die "cannot install ufw"
}

firewall_allow() {
	firewall_ensure
	ufw allow "${1%%:*}" comment "${1#*:}" >/dev/null
}

firewall_delete() {
	command -v ufw >/dev/null 2>&1 || return 0
	local n
	for n in $(ufw status numbered 2>/dev/null | awk -v c="# $1" '
		substr($0, length($0) - length(c) + 1) == c {
			sub(/^\[ */, ""); sub(/\].*/, ""); print
		}' | sort -rn); do
		ufw --force delete "$n" >/dev/null 2>&1 || true
	done
}

firewall_route_allow() {
	firewall_ensure
	ufw route allow in on "$1" comment "$2" >/dev/null
}

ssh_ports() {
	{
		sshd -T 2>/dev/null | awk '$1 == "port" { print $2 }'
		ss -Htlnp 2>/dev/null | awk '/"sshd"/ { sub(/.*:/, "", $4); print $4 }'
	} | sort -un
}

firewall_apply() {
	firewall_ensure
	local spec ports p
	ports=$(ssh_ports)
	for p in $ports; do
		firewall_allow "$p/tcp:SSH"
	done
	for spec in "$@"; do
		firewall_allow "$spec"
	done
	ufw status | grep -q '^Status: active' && return 0
	if [ -z "$ports" ]; then
		warn "cannot tell which port sshd listens on, ufw stays disabled — allow SSH and run 'ufw enable' yourself"
		return 0
	fi
	ufw --force enable >/dev/null
}
