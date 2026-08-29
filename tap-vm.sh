#!/usr/bin/env bash

set -u -e -o pipefail
shopt -s nullglob

# validate inputs
MASQ_TAP_IF="${MASQ_TAP_IF?Tap interface name is required in env MASQ_TAP_IF}"
MASQ_TAP_GW_IP="${MASQ_TAP_GW_IP?Gateway ip address is required in env MASQ_TAP_GW_IP}"
MASQ_TAP_VM_IP="${MASQ_TAP_VM_IP?VM ip address is required in env MASQ_TAP_VM_IP}"
MASQ_TAP_SUFFIX="${MASQ_TAP_SUFFIX?VM/GW network suffix number is required in env MASQ_TAP_SUFFIX}"

# manage input
VM_IMAGE_FILE="${VM_IMAGE_FILE:-${1:-}}"
[ -n "${VM_IMAGE_FILE}" ] || {
  echo "Input qcow2 base image URL missing" >&2
  exit 1
}
VM_DISK_FILE="${VM_DISK_FILE:-${2:-}}"
[ -n "${VM_DISK_FILE}" ] || {
  echo "Output VM disk qcow2 path missing" >&2
  exit 1
}

# create a new disk, removing the existing one
VM_NAME="${VM_NAME:-sandbox}"
VM_SIZE="${VM_SIZE:-10G}"
VM_RAM="${VM_RAM:-2G}"
VM_CPU="${VM_CPU:-1}"
VM_ALLOW_PASSWORD="${VM_ALLOW_PASSWORD:-0}"
[ -f "${VM_DISK_FILE}" ] && rm -v "${VM_DISK_FILE}"
qemu-img create -f qcow2 -b "${VM_IMAGE_FILE}" -F qcow2 "${VM_DISK_FILE}" "${VM_SIZE}"

cleanup_image() {
  # prune the disk if not asked to keep it
  [ "${KEEP_DISK_FILE:-0}" -eq 0 ] && [ -f "${VM_DISK_FILE}" ] && rm -v "${VM_DISK_FILE}"
}
trap 'cleanup_image' EXIT

# create cloud init configuration image
TEMP_CONFIGDRIVE="$(mktemp --directory --suffix '-config-drive')"
cleanup_config() {
  rm --recursive --force "${TEMP_CONFIGDRIVE}"
}
trap 'cleanup_config; cleanup_image;' EXIT
CONFIGDRIVE="${TEMP_CONFIGDRIVE}/configdrive"
mkdir --parent "${CONFIGDRIVE}"
SSH_PUB_KEY_FILE="${SSH_PUB_KEY_FILE:-${HOME}/.ssh/id_ed25519.pub}"
PACKAGE_UPGRADE="${PACKAGE_UPGRADE:-false}"

cat <<EOF | tee network-config >"${CONFIGDRIVE}/network-config"
version: 2
ethernets:
  ens3:
    dhcp4: false
    dhcp6: false
    addresses:
      - ${MASQ_TAP_VM_IP}/${MASQ_TAP_SUFFIX}
    routes:
      - to: default
        via: ${MASQ_TAP_GW_IP}
    nameservers:
      addresses:
        - 8.8.8.8
        - 1.1.1.1
EOF

cat <<EOF | tee user-data >"${CONFIGDRIVE}/user-data"
#cloud-configdebian"
hostname: ${VM_NAME}
fqdn: ${VM_NAME}.lan

users:
  - name: debian
    gecos: Debian user
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
$(
  if [[ "${VM_ALLOW_PASSWORD}" -eq 0 ]]; then
    echo "    lock_passwd: true"
  else
    echo "    lock_passwd: false"
    echo "    plain_text_passwd: DEBIAN"
  fi
)
    ssh_authorized_keys:
      - $(cat "${SSH_PUB_KEY_FILE}")
      - $(cat "${HOME}/.ssh/id_ed25519_ansible_user.pub")
  - name: root
    ssh_authorized_keys:
      - $(cat "${SSH_PUB_KEY_FILE}")
      - $(cat "${HOME}/.ssh/id_ed25519_ansible_user.pub")
EOF

cat <<EOF | tee meta-data >"${CONFIGDRIVE}/meta-data"
{
  "instance-id": "${VM_NAME}",
  "local-hostname": "${VM_NAME}"
}
EOF

CONFIGDRIVE_ISO="${TEMP_CONFIGDRIVE}/configdrive.iso"
xorriso -as mkisofs -o "${CONFIGDRIVE_ISO}" -V cidata -J -r "${CONFIGDRIVE}"

# prepare port forwarding options
VM_FORWARDS="${VM_FORWARDS:-2222:22}"

# host networking
NETDEV="tap,id=net0,ifname=${MASQ_TAP_IF},script=no,downscript=no"

# run the VM with the provided option
echo "Running VM ${VM_NAME} ... Press ctrl-a then c to get into qemu monitor, then quit to exit."

qemu-system-x86_64 \
  -machine pc,graphics=off,i8042=off,usb=off,smbus=off,sata=off,pit=off,hpet=off,pic=off,vmport=off \
  -m "${VM_RAM}" \
  -smp "${VM_CPU}" \
  -enable-kvm \
  -drive file="${VM_DISK_FILE}",format=qcow2,if=virtio \
  -drive file="${CONFIGDRIVE_ISO}",format=raw,if=virtio,read-only=on \
  -netdev "${NETDEV}" \
  -device virtio-net-pci,netdev=net0 \
  -display none \
  -serial mon:stdio
