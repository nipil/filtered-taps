#!/bin/sh

VM_ALLOW_PASSWORD=1 MASQ_TAP_IF=$USER MASQ_TAP_GW_IP=$(getent hosts gateway_$USER | awk '{ print $1 }') MASQ_TAP_VM_IP=$(getent hosts $USER | awk '{ print $1 }') MASQ_TAP_SUFFIX=30 /opt/qemu/tap-vm.sh /opt/qemu/upstream/debian-trixie-genericcloud-amd64-20260831-2587.qcow2 ~/a.qcow2
