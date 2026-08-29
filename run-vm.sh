#!/usr/bin/env bash

set -u -e -o pipefail
shopt -s nullglob

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
[ -f "${VM_DISK_FILE}" ] && rm -v "${VM_DISK_FILE}"
qemu-img create -f qcow2 -b "${VM_IMAGE_FILE}" -F qcow2 "${VM_DISK_FILE}" "${VM_SIZE}"

# create cloud init configuration image
TEMP_CONFIGDRIVE="$(mktemp --directory --suffix '-config-drive')"
trap 'rm --recursive --force "${TEMP_CONFIGDRIVE}"' EXIT

CONFIGDRIVE="${TEMP_CONFIGDRIVE}/configdrive"
mkdir --parent "${CONFIGDRIVE}"
SSH_PUB_KEY_FILE="${SSH_PUB_KEY_FILE:-${HOME}/.ssh/id_ed25519.pub}"
PACKAGE_UPGRADE="${PACKAGE_UPGRADE:-false}"

# to use an encrypted password
# - generate using `openssl passwd -6`
# - replace plain_text_passwd with passwd
# - escape each $ in password hash
# password locking
# - true by default
# - need to be false to login on console
cat >"${CONFIGDRIVE}/user-data" <<EOF
#cloud-config
hostname: ${VM_NAME}
fqdn: ${VM_NAME}.lan
package_upgrade: ${PACKAGE_UPGRADE}
packages:
  - openssh-server
users:
  - name: debian
    gecos: Debian user
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
    plain_text_passwd: DEBIAN
    ssh_authorized_keys:
      - $(cat "${SSH_PUB_KEY_FILE}")
      - $(cat "${HOME}/.ssh/id_ed25519_ansible_user.pub")
  - name: root
    ssh_authorized_keys:
      - $(cat "${SSH_PUB_KEY_FILE}")
      - $(cat "${HOME}/.ssh/id_ed25519_ansible_user.pub")
runcmd:
  - systemctl enable ssh
  - systemctl start ssh
EOF

cat >"${CONFIGDRIVE}/meta-data" <<EOF
{
  "instance-id": "${VM_NAME}",
  "local-hostname": "${VM_NAME}"
}
EOF

CONFIGDRIVE_ISO="${TEMP_CONFIGDRIVE}/configdrive.iso"
xorriso -as mkisofs -o "${CONFIGDRIVE_ISO}" -V cidata -J -r "${CONFIGDRIVE}"

# prepare port forwarding options
VM_FORWARDS="${VM_FORWARDS:-2222:22}"
NETDEV='user,id=net0'
OLD_IFS="${IFS}"
IFS=,
for VM_FORWARD in $VM_FORWARDS; do
  NETDEV+=",hostfwd=tcp:127.0.0.1:${VM_FORWARD/:/-:}"
done
IFS="${OLD_IFS}"

# run the VM with the provided option
echo "Running VM ${VM_NAME} ... Press ctrl-a then c to get into qemu monitor, then quit to exit."
qemu-system-x86_64 \
  -m "${VM_RAM}" \
  -smp "${VM_CPU}" \
  -enable-kvm \
  -drive file="${VM_DISK_FILE}",format=qcow2 \
  -drive file="${CONFIGDRIVE_ISO}",media=cdrom \
  -netdev "${NETDEV}" \
  -device virtio-net-pci,netdev=net0 \
  -display none \
  -serial mon:stdio

# prune the disk if not asked to keep it
[ "${KEEP_DISK_FILE:-0}" -eq 0 ] && [ -f "${VM_DISK_FILE}" ] && rm -v "${VM_DISK_FILE}"
