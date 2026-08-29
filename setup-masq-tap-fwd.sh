#!/usr/bin/env bash

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

if TAP_STATE=$(
    ip --oneline link show dev tap0 2>/dev/null |
        awk '{
            for (i=1; i<=NF; i++)
                if ($i=="state")
                    print tolower($(i+1))
        }'
) && [[ ${TAP_STATE} != "down" ]]; then
    echo "${HOST_TAP_IFNAME}" is alreay in use >&2
    exit 2
fi

VM_IP="${SUBNET_PREFIX}".$((N * SUBNET_SIZE + 1))
GW_IP="${SUBNET_PREFIX}".$((N * SUBNET_SIZE + 2))

# ============================================================
# Install nftables to allow firewall configuration
# ============================================================

sudo apt-get install --quiet --quiet --yes nftables

# ============================================================
# Setup interfaces and addresses
# ============================================================

if ! ip link show dev "${HOST_TAP_IFNAME}" &>/dev/null; then
    sudo ip tuntap add "${HOST_TAP_IFNAME}" mode tap user "${USER}"
fi

if ! ip -4 addr show dev "${HOST_TAP_IFNAME}" | grep "" &>/dev/null; then
    sudo ip addr add "${GW_IP}/${SUBNET_SUFFIX}" dev "${HOST_TAP_IFNAME}"
fi

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
# NFT helpers to simplify
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

[[ -n "${TABLE_DELETE:-}" ]] && sudo nft delete table ip "${TABLE_INPUT}"

# Create an IPv4 routing table which will be used for filtering
if ! nft_table_exists ip "${TABLE_INPUT}"; then
    sudo nft add table ip "${TABLE_INPUT}"
fi

# Create a filter chain attached to the forward hook
# TODO: check why this table will be selected for that trafic

if ! nft_chain_exists ip "${TABLE_INPUT}" input; then
    # IMPORTANT: we allow by default because we allow "VM to the host"
    # TODO: verify host to vm OK and vm to host REJECT
    sudo nft "add chain ip ${TABLE_INPUT} input {
        type filter hook input priority filter;
        policy accept;
    }"
fi

# Loopback always allowed
COMMENT_LOOPBACK=filter-allow-loopback
if ! nft_rule_exists ip "${TABLE_INPUT}" input "${COMMENT_LOOPBACK}"; then
    sudo nft add rule ip "${TABLE_INPUT}" input \
        iif lo \
        accept \
        comment "${COMMENT_LOOPBACK}"
fi

# Drop all packets from sandbox interface to the host
COMMENT_SANDBOX_REJECT=filter-sandbox-reject
if ! nft_rule_exists ip "${TABLE_INPUT}" input "${COMMENT_SANDBOX_REJECT}"; then
    sudo nft add rule ip "${TABLE_INPUT}" input \
        iifname "${HOST_TAP_IFNAME}" \
        reject \
        comment "${COMMENT_SANDBOX_REJECT}"
fi

# sudo nft -s list ruleset

TABLE_FORWARD=sandbox_forward

[[ -n "${TABLE_DELETE:-}" ]] && sudo nft delete table ip "${TABLE_FORWARD}"

# Create an IPv4 routing table which will be used for filtering
if ! nft_table_exists ip "${TABLE_FORWARD}"; then
    sudo nft add table ip "${TABLE_FORWARD}"
fi

# Create a filter chain attached to the forward hook
# TODO: check why this table will be selected for that trafic

if ! nft_chain_exists ip "${TABLE_FORWARD}" forward; then
    # IMPORTANT: we allow by default because we allow "VM to the whole internet" (for now)
    # INFO: this same rule is what allows the host to reach the vm
    # TODO: verify host to vm OK and vm to host REJECT
    sudo nft "add chain ip ${TABLE_FORWARD} forward {
        type filter hook forward priority filter;
        policy accept;
    }"
fi

# Replies to already established connections
COMMENT_ESTABLISHED=filter-established
if ! nft_rule_exists ip "${TABLE_FORWARD}" forward "${COMMENT_ESTABLISHED}"; then
    sudo nft add rule ip "${TABLE_FORWARD}" forward \
        ct state established,related \
        accept \
        comment "${COMMENT_ESTABLISHED}"
fi

# Forbid VM to anything private and reject instead of drop to help diagnose
COMMENT_PRIVATE=filter-private-127
if ! nft_rule_exists ip "${TABLE_FORWARD}" forward "${COMMENT_PRIVATE}"; then
    sudo nft add rule ip "${TABLE_FORWARD}" forward \
        iifname "${HOST_TAP_IFNAME}" \
        oifname "${HOST_INTERNET_IFNAME}" \
        ip daddr 127.0.0.0/8 \
        reject \
        comment "${COMMENT_PRIVATE}"
fi

COMMENT_PRIVATE=filter-private-10
if ! nft_rule_exists ip "${TABLE_FORWARD}" forward "${COMMENT_PRIVATE}"; then
    sudo nft add rule ip "${TABLE_FORWARD}" forward \
        iifname "${HOST_TAP_IFNAME}" \
        oifname "${HOST_INTERNET_IFNAME}" \
        ip daddr 10.0.0.0/8 \
        reject \
        comment "${COMMENT_PRIVATE}"
fi

COMMENT_PRIVATE=filter-private-192
if ! nft_rule_exists ip "${TABLE_FORWARD}" forward "${COMMENT_PRIVATE}"; then
    sudo nft add rule ip "${TABLE_FORWARD}" forward \
        iifname "${HOST_TAP_IFNAME}" \
        oifname "${HOST_INTERNET_IFNAME}" \
        ip daddr 192.168.0.0/16 \
        reject \
        comment "${COMMENT_PRIVATE}"
fi

COMMENT_PRIVATE=filter-private-172
if ! nft_rule_exists ip "${TABLE_FORWARD}" forward "${COMMENT_PRIVATE}"; then
    sudo nft add rule ip "${TABLE_FORWARD}" forward \
        iifname "${HOST_TAP_IFNAME}" \
        oifname "${HOST_INTERNET_IFNAME}" \
        ip daddr 172.16.0.0/12 \
        reject \
        comment "${COMMENT_PRIVATE}"
fi

# sudo nft -s list ruleset

# ============================================================
# Host NAT
# ============================================================

TABLE_POSTROUTING=sandbox_postrouting

[[ -n "${TABLE_DELETE:-}" ]] && sudo nft delete table ip "${TABLE_POSTROUTING}"

# Create an IPv4 routing table which will be used for doing NAT
if ! nft_table_exists ip "${TABLE_POSTROUTING}"; then
    sudo nft add table ip "${TABLE_POSTROUTING}"
fi

# Create a postrouting chain attached to the NAT hook
# TODO: check that the policy accept is indeed what we want
# TODO: check why this table will be selected for that trafic

if ! nft_chain_exists ip "${TABLE_POSTROUTING}" postrouting; then
    sudo nft "add chain ip ${TABLE_POSTROUTING} postrouting {
        type nat hook postrouting priority srcnat;
        policy accept;
    }"
fi

# Masquerade traffic leaving through the Internet interface
# for packets coming from the vm network and going out of the host
COMMENT_MASQUERADING=sandbox-masquerading
if ! nft_rule_exists ip "${TABLE_POSTROUTING}" postrouting "${COMMENT_MASQUERADING}"; then
    sudo nft add rule ip "${TABLE_POSTROUTING}" postrouting \
        iifname "${HOST_TAP_IFNAME}" \
        oifname "${HOST_INTERNET_IFNAME}" \
        masquerade \
        comment "${COMMENT_MASQUERADING}"
fi

# sudo nft -s list ruleset

# ============================================================
# Now that FW is configured, allow forwarding and bring if up
# ============================================================

# Enable IPv4 forwarding on the host
sudo sysctl --quiet --write net.ipv4.ip_forward=1

# ============================================================
# Output the current state so the caller can "eval"
# ============================================================

echo "export MASQ_TAP_IF=\"${HOST_TAP_IFNAME}\""
echo "export MASQ_TAP_VM_IP=\"${VM_IP}\""
echo "export MASQ_TAP_GW_IP=\"${GW_IP}\""
echo "export MASQ_TAP_SUFFIX=\"${SUBNET_SUFFIX}\""
