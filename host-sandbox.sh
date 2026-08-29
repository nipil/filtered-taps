#!/usr/bin/env bash

set -e -u -o pipefail

# Only those instruction that require privileges are marked as such

# ============================================================
# topology information
# ============================================================

# Find internet interface for the host
HOST_INTERNET_IFNAME=$(
    ip route list default |
        head --lines 1 |
        awk '{for (i=1; i<=NF; i++) if ($i=="dev") print $(i+1)}'
)

# name of the network namespace which will collect the network traffic of the vm
NET_NS_SANDBOX=sandbox

HOST_VETH=veth-host
HOST_IP=192.168.2.1/30

SANDBOX_VETH=veth-sandbox
SANDBOX_IP=192.168.2.2/30

VM_NETWORK=192.168.3.0/24

ALLOWED_IP="203.0.113.10" # TEST-NET-3 /24

# ============================================================
# Setup interfaces and addresses
# ============================================================

# install nftables to allow firewall configuration
sudo apt-get install --quiet --quiet --yes nftables

# Create the sandbox network namespace on the host
ip netns list |
    awk '{print $1}' |
    grep --fixed-strings --line-regexp --quiet "${NET_NS_SANDBOX}" ||
    sudo ip netns add "${NET_NS_SANDBOX}"

# Create the host <-> sandbox veth pair
ip link show "${HOST_VETH}" &>/dev/null ||
    sudo ip link add "${HOST_VETH}" type veth peer name "${SANDBOX_VETH}"

# Move the sandbox veth to the sandbox network namespace
# Only needed if it hasn't already been moved.
# NOTE: requires privileges, otherwise the interface is unseen
if ! sudo ip --netns "${NET_NS_SANDBOX}" link show "${SANDBOX_VETH}" &>/dev/null; then
    sudo ip link set "${SANDBOX_VETH}" netns "${NET_NS_SANDBOX}"
fi

# Bring interfaces up
sudo ip link set "${HOST_VETH}" up
sudo ip --netns "${NET_NS_SANDBOX}" link set lo up
sudo ip --netns "${NET_NS_SANDBOX}" link set "${SANDBOX_VETH}" up

# Configure the host side of the veth
# NOTE: requires privileges, otherwise the interface is unseen
ip addr show dev "${HOST_VETH}" |
    grep --fixed-strings --quiet "inet ${HOST_IP}" ||
    sudo ip addr add "${HOST_IP}" dev "${HOST_VETH}"

# Configure the sandbox side of the veth
# NOTE: requires privileges, otherwise the interface is unseen
sudo ip --netns "${NET_NS_SANDBOX}" addr show dev "${SANDBOX_VETH}" |
    grep --fixed-strings --quiet "inet ${SANDBOX_IP}" ||
    sudo ip --netns "${NET_NS_SANDBOX}" addr add "${SANDBOX_IP}" dev "${SANDBOX_VETH}"

# Add route to host to be able to reach VM directly through NS
ip route show "${VM_NETWORK}" |
    grep --fixed-strings --quiet "via ${SANDBOX_IP%/*} dev ${HOST_VETH}" ||
    sudo ip route add "${VM_NETWORK}" via "${SANDBOX_IP%/*}" dev "${HOST_VETH}"

# Make all outside trafic go through the host
sudo ip --netns "${NET_NS_SANDBOX}" route show default |
    grep --fixed-strings --quiet "via ${HOST_IP%/*}" ||
    sudo ip --netns "${NET_NS_SANDBOX}" route add default via "${HOST_IP%/*}"

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
# Host NAT
# ============================================================

TABLE_MASQUERADING=sandbox_masquerading

[[ -n "${TABLE_DELETE:-}" ]] && sudo nft delete table ip "${TABLE_MASQUERADING}"

# Create an IPv4 routing table which will be used for doing NAT
if ! nft_table_exists ip "${TABLE_MASQUERADING}"; then
    sudo nft add table ip "${TABLE_MASQUERADING}"
fi

# Create a postrouting chain attached to the NAT hook
# TODO: check that the policy accept is indeed what we want
# TODO: check why this table will be selected for that trafic

if ! nft_chain_exists ip "${TABLE_MASQUERADING}" postrouting; then
    sudo nft "add chain ip ${TABLE_MASQUERADING} postrouting {
        type nat hook postrouting priority srcnat;
        policy accept;
    }"
fi

# Masquerade traffic leaving through the Internet interface
# for packets coming from the vm network and going out of the host
COMMENT_MASQUERADING=sandbox-masquerading
if ! nft_rule_exists ip "${TABLE_MASQUERADING}" postrouting "${COMMENT_MASQUERADING}"; then
    sudo nft add rule ip "${TABLE_MASQUERADING}" postrouting \
        ip saddr "${VM_NETWORK}" \
        oifname "${HOST_INTERNET_IFNAME}" \
        masquerade \
        comment "${COMMENT_MASQUERADING}"
fi

# ============================================================
# Host firewall
# ============================================================

TABLE_FILTER=sandbox_filter

[[ -n "${TABLE_DELETE:-}" ]] && sudo nft delete table ip "${TABLE_FILTER}"

# create an IPv4 routing table which will be used for filtering
if ! nft_table_exists ip "${TABLE_FILTER}"; then
    sudo nft add table ip "${TABLE_FILTER}"
fi

# add chain working to filter during forwarding
# TODO: check that the policy accept is indeed what we want
if ! nft_chain_exists ip "${TABLE_FILTER}" forward; then
    sudo nft "add chain ip ${TABLE_FILTER} forward {
        type filter hook forward priority filter;
        policy accept;
    }"
fi

# TODO: check that a incoming stage is required to protect the host itself
# TODO: check that it works on all interfaces

# accept already established connections (ie. replies)
COMMENT_ESTABLISHED=sandbox-established
if ! nft_rule_exists ip "${TABLE_FILTER}" forward "${COMMENT_ESTABLISHED}"; then
    sudo nft add rule ip "${TABLE_FILTER}" forward \
        ct state established,related \
        accept \
        comment "${COMMENT_ESTABLISHED}"
fi

# TODO: check to add invalid packet drop

# allow VM to reach the single allowed IP
COMMENT_ALLOWED_DESTINATION=sandbox-allowed-destination
if ! nft_rule_exists ip "${TABLE_FILTER}" forward "${COMMENT_ALLOWED_DESTINATION}"; then
    sudo nft add rule ip "${TABLE_FILTER}" forward \
        iifname "${HOST_VETH}" \
        ip saddr "${VM_NETWORK}" \
        ip daddr "${ALLOWED_IP}" \
        accept \
        comment "${COMMENT_ALLOWED_DESTINATION}"
fi

# deny everything else comming from sandbox netword namespace
COMMENT_DROPPED=sandbox-drop
if ! nft_rule_exists ip "${TABLE_FILTER}" forward "${COMMENT_DROPPED}"; then
    sudo nft add rule ip "${TABLE_FILTER}" forward \
        iifname "${HOST_VETH}" \
        drop \
        comment "${COMMENT_DROPPED}"
fi

# TODO: check if needed or not: ip saddr 192.0.3.0/30 \

sudo nft -s list ruleset

# ============================================================
# Now that FW is configured, allow forwarding and bring if up
# ============================================================

# Enable IPv4 forwarding on the host
sudo sysctl --quiet --write net.ipv4.ip_forward=1

# Enable IPv4 forwarding in the sandbox namespace
sudo ip netns exec "${NET_NS_SANDBOX}" sysctl --quiet --write net.ipv4.ip_forward=1

# sudo ip netns exec "${NET_NS_SANDBOX}" touch /toto
# $ ls -l /toto
# -rw-r--r-- 1 root root 0 24 août  18:59 /toto
