#!/usr/bin/env bash

# sudo nft flush ruleset

# Usage:
#
# $ eval $(./setup_masq_tap_fwd.sh 0)
#
# $ env | grep MASQ_TAP_
# MASQ_TAP_SUFFIX=30
# MASQ_TAP_VM_IP=192.168.255.1
# MASQ_TAP_GW_IP=192.168.255.2
# MASQ_TAP_IF=tap0

SUBNET_PREFIX=192.168.255
SUBNET_SIZE=4
SUBNET_SUFFIX=30 # keep in sync with size

set -e -u -o pipefail

N=${1?Requires tap interface index as first argument}

if [[ "$N" -ge $((256 / SUBNET_SIZE)) ]]; then
    echo Index "${N}" is too large for network capacity >&2
    exit 1
fi

HOST_TAP_IFNAME=tap"${N}"

VM_IP="${SUBNET_PREFIX}".$((N * SUBNET_SIZE + 1))
GW_IP="${SUBNET_PREFIX}".$((N * SUBNET_SIZE + 2))

# ============================================================
# Do not forward even spoofed packets from vms
# ============================================================

# all = for existing ifaces, default = for future created ones

# disable IPv6 forwarding on the host
sudo sysctl --quiet --write net.ipv6.conf.all.forwarding=0
sudo sysctl --quiet --write net.ipv6.conf.default.forwarding=0

# disable IPv4 broadcast forwarding (does not exist for IPv6)
sudo sysctl --quiet --write net.ipv4.conf.all.bc_forwarding=0
sudo sysctl --quiet --write net.ipv4.conf.default.bc_forwarding=0

# multicast forwarding ise disabled/enabled by multicast daemons
# (so readonly) : only check and halt on surprises
for family in ipv{4,6}; do
    for scope in all default; do
        key=net."$family".conf."$scope".mc_forwarding
        # sysctl it is in /usr/sbin (not in PATH of non-root user)
        val=$(/usr/sbin/sysctl --quiet --values "$key")
        if [[ "$val" -ne 0 ]]; then
            echo "Expected ${key} = 0, got ${val}" >&2
            exit 1
        fi
    done
done

# ============================================================
# Install nftables to allow firewall configuration
# ============================================================

# for address families: ip = IPv4, ip6 = IPv6, inet = IPv4/IPv6

sudo apt-get install --quiet --quiet --yes nftables

# ============================================================
# Setup interfaces and addresses
# ============================================================

if ! ip link show dev "${HOST_TAP_IFNAME}" &>/dev/null; then
    sudo ip tuntap add "${HOST_TAP_IFNAME}" mode tap user "${USER}"
fi

GW_IP_MASK="${GW_IP}/${SUBNET_SUFFIX}"

# helper to not repeat ourselves
tap_addr_field() {
    ip -oneline -4 addr show dev "${HOST_TAP_IFNAME}" | awk '{ print $4 }'
}

# add the specified IP address if missing
if ! tap_addr_field | grep --quiet --line-regexp --fixed-strings "${GW_IP_MASK}"; then
    sudo ip addr add "${GW_IP_MASK}" dev "${HOST_TAP_IFNAME}"
fi

# allow authoritative host changes, breaking the vm networking if needed.
# removes any "unspecified"" IPv4 ONLY address, but does not touch IPv6 (for now)
# Why ? any link-local IPv6 is automatic and managed by the kernel, and IPv6 local
# addresses are required for IPv6 routing (if later configured and allowed)
tap_addr_field | {
    grep --invert-match --line-regexp --fixed-strings "${GW_IP_MASK}" ||
        true # required so that an empty match does not error with pipefail
} | xargs -I ADDR sudo ip addr del ADDR dev "${HOST_TAP_IFNAME}"

# allow the interface to be used
sudo ip link set dev "${HOST_TAP_IFNAME}" up

# ============================================================
# topology information
# ============================================================

# Find internet interface for the host
HOST_INTERNET_IFNAME=$(
    ip route list default |
        head --lines 1 |
        awk '{
            for (i=1; i<=NF; i++)
                if ($i=="dev")
                    print $(i+1)
        }'
)

# ============================================================
# NFT first-level helpers
# ============================================================

nft_table_exists() {
    sudo nft --json list table "$1" "$2" &>/dev/null
}

nft_chain_exists() {
    sudo nft --json list chain "$1" "$2" "$3" &>/dev/null
}

nft_rule_exists() {
    local family=$1
    local table=$2
    local chain=$3
    local comment=$4

    # IMPORTANT: comment is the actual identity of the rule
    # so do not use generic text here, and make it stick !
    # jq checks each elment and tests if any has a
    # .rule.comment matching the value, result as exit status
    sudo nft --json list chain "$family" "$table" "$chain" |
        jq --exit-status --arg comment "$comment" '
            any(.nftables[]; .rule.comment? == $comment)
        ' >/dev/null
}

# ============================================================
# NFT second-level helpers
#
# Generic idempotency guard shared by table/chain/rule creation.
#
#   ensure_nft <exists_fn> <exists_fn_arg>... -- <nft_add_arg>...
# ============================================================
ensure_nft() {
    local exists_fn=$1
    shift

    local exists_args=()
    while [[ "$1" != "--" ]]; do
        exists_args+=("$1")
        shift
    done
    shift # drop the --

    if ! "${exists_fn}" "${exists_args[@]}"; then
        sudo nft "$@"
    fi
}

# Thin, purpose-named wrappers around ensure_nft so call sites stay
# readable and keep the same argument shape as before the refactor.

ensure_nft_table() {
    local family=$1 table=$2
    ensure_nft nft_table_exists "${family}" "${table}" -- \
        add table "${family}" "${table}"
}

ensure_nft_chain() {
    local family=$1 table=$2 chain=$3 chain_def=$4
    ensure_nft nft_chain_exists "${family}" "${table}" "${chain}" -- \
        "add chain ${family} ${table} ${chain} ${chain_def}"
}

ensure_nft_rule() {
    local family=$1 table=$2 chain=$3 comment=$4
    shift 4
    # IMPORTANT: comment is the actual identity of the rule
    # so do not use generic text here, and make it stick !
    ensure_nft nft_rule_exists "${family}" "${table}" "${chain}" "${comment}" -- \
        add rule "${family}" "${table}" "${chain}" "$@" comment "${comment}"
}

# ============================================================
# VM network filtering
# ============================================================

# NAMED PRIORITIES
# raw -300 (before connection tracking)
# mangle -150 (mangle)
# dstnat -100 (prerouting only)
# filter 0
# security 50 (where secmark can be set, SELinux, etc.)
# srcnat 100 (postrouting only)

# for INPUT chain, to protect the host, from iifname
TABLE_INPUT=sandbox_input

[[ -n "${TABLE_DELETE:-}" ]] && sudo nft delete table inet "${TABLE_INPUT}"

# Create an IPv4 routing table which will be used for filtering
ensure_nft_table inet "${TABLE_INPUT}"

# Create a filter chain attached to the input hook
ensure_nft_chain inet "${TABLE_INPUT}" input '{
        type filter hook input priority filter;
        policy accept;
    }'

# Drop invalid before doing anything else
ensure_nft_rule inet "${TABLE_INPUT}" input filter-invalid \
    ct state invalid \
    drop

# Replies to already established connections
ensure_nft_rule inet "${TABLE_INPUT}" input filter-established \
    ct state established,related \
    accept

# Loopback always allowed
ensure_nft_rule inet "${TABLE_INPUT}" input filter-allow-loopback \
    iif lo \
    accept

# Drop all packets from sandbox interface to the host
ensure_nft_rule inet "${TABLE_INPUT}" input filter-sandbox-reject \
    iifname "${HOST_TAP_IFNAME}" \
    reject

# sudo nft -s list ruleset

TABLE_FORWARD=sandbox_forward

[[ -n "${TABLE_DELETE:-}" ]] && sudo nft delete table inet "${TABLE_FORWARD}"

# Create an IPv4 routing table which will be used for filtering
ensure_nft_table inet "${TABLE_FORWARD}"

# Create a filter chain attached to the forward hook
# IMPORTANT: we allow by default because we allow "VM to the whole internet" (for now)
ensure_nft_chain inet "${TABLE_FORWARD}" forward '{
        type filter hook forward priority filter;
        policy accept;
    }'

# Drop invalid before doing anything else
ensure_nft_rule inet "${TABLE_FORWARD}" forward filter-invalid \
    ct state invalid \
    drop

# Replies to already established connections
ensure_nft_rule inet "${TABLE_FORWARD}" forward filter-established \
    ct state established,related \
    accept

## EXPLICIT REJECT "LOCAL" RULES
# Forbid VM to anything private and reject instead of drop to help diagnose

ensure_nft_rule inet "${TABLE_FORWARD}" forward filter-private-ip4-10 \
    iifname "${HOST_TAP_IFNAME}" \
    ip daddr 10.0.0.0/8 \
    reject

ensure_nft_rule inet "${TABLE_FORWARD}" forward filter-private-ip4-192 \
    iifname "${HOST_TAP_IFNAME}" \
    ip daddr 192.168.0.0/16 \
    reject

ensure_nft_rule inet "${TABLE_FORWARD}" forward filter-private-ip4-172 \
    iifname "${HOST_TAP_IFNAME}" \
    ip daddr 172.16.0.0/12 \
    reject

ensure_nft_rule inet "${TABLE_FORWARD}" forward filter-private-ip6-mapped-ip4 \
    iifname "${HOST_TAP_IFNAME}" \
    ip6 daddr ::ffff:0:0/96 \
    reject

ensure_nft_rule inet "${TABLE_FORWARD}" forward filter-private-ip6-fc00 \
    iifname "${HOST_TAP_IFNAME}" \
    ip6 daddr fc00::/7 \
    reject

ensure_nft_rule inet "${TABLE_FORWARD}" forward filter-private-ip6-fe80 \
    iifname "${HOST_TAP_IFNAME}" \
    ip6 daddr fe80::/10 \
    reject

## EXPLICIT MARTIAN RULES
# These are the textbook definition of a "martian" packet automatically
# dropped by the kernel, and as such, a dead rule that must never match
# i keep it solely for completeness so i do not wonder later why i did not
# add it, and to have a place to put this very comment for later readers.

ensure_nft_rule inet "${TABLE_FORWARD}" forward filter-private-ip6-1 \
    iifname "${HOST_TAP_IFNAME}" \
    ip6 daddr ::1/128 \
    reject

# Forbid VM to anything private and reject instead of drop to help diagnose
ensure_nft_rule inet "${TABLE_FORWARD}" forward filter-private-ip4-127 \
    iifname "${HOST_TAP_IFNAME}" \
    ip daddr 127.0.0.0/8 \
    reject

# sudo nft -s list ruleset

# ============================================================
# Host NAT
# ============================================================

TABLE_POSTROUTING=sandbox_postrouting

[[ -n "${TABLE_DELETE:-}" ]] && sudo nft delete table inet "${TABLE_POSTROUTING}"

# Create an IPv4 routing table which will be used for doing NAT
ensure_nft_table inet "${TABLE_POSTROUTING}"

# Create a postrouting chain attached to the NAT hook
ensure_nft_chain inet "${TABLE_POSTROUTING}" postrouting '{
        type nat hook postrouting priority srcnat;
        policy accept;
    }'

# Masquerade traffic leaving through the Internet interface
# for packets coming from the vm network and going out of the host
ensure_nft_rule inet "${TABLE_POSTROUTING}" postrouting sandbox-masquerading \
    iifname "${HOST_TAP_IFNAME}" \
    oifname "${HOST_INTERNET_IFNAME}" \
    masquerade

# sudo nft -s list ruleset

# ============================================================
# Now that FW is configured, allow forwarding and bring if up
# ============================================================

# Enable IPv4 forwarding on the host (existing interfaces)
# all = for existing ifaces, default = for future created ones
sudo sysctl --quiet --write net.ipv4.conf.all.forwarding=1
sudo sysctl --quiet --write net.ipv4.conf.default.forwarding=1

# ============================================================
# Output the current state so the caller can "eval"
# ============================================================

echo "export MASQ_TAP_IF=\"${HOST_TAP_IFNAME}\""
echo "export MASQ_TAP_VM_IP=\"${VM_IP}\""
echo "export MASQ_TAP_GW_IP=\"${GW_IP}\""
echo "export MASQ_TAP_SUFFIX=\"${SUBNET_SUFFIX}\""
