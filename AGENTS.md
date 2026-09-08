# AGENTS.md

QEMU VM scripts that attach a cloud-init VM to a host-owned tap interface backed by a NAT/masquerade gateway. Not self-contained: the tap interface (`script=no`, `downscript=no`) and gateway IPs must already exist.

## Scripts

- `tap-vm.sh` — main launcher (`qemu-system-x86_64`, KVM). Required env: `MASQ_TAP_IF`, `MASQ_TAP_GW_IP`, `MASQ_TAP_VM_IP`, `MASQ_TAP_SUFFIX`. Positional args: base qcow2 image, output disk path. Creates a qcow2 overlay (backing = base image), builds a cloud-init config drive in the repo cwd, and adds no port forwarding (VM is reached directly via the tap network).
- `get-debian-images.sh` — downloads a Debian cloud image to `./images`, SHA512-verified; the final filename appears only after verification passes. Defaults: `trixie genericcloud amd64 qcow2`.
- `sandbox-qemu.sh` — wrapper resolving `gateway_$USER` / `$USER` through `getent hosts` (needs /etc/hosts entries; tap iface = `$USER`). Hardcodes the `/opt/qemu/...` deploy path — scripts must be installed there to run as-is.
- `wip/microvm.sh` — work in progress, not standalone: a fragment meant to be merged into `tap-vm.sh` (uses its traps, `VM_DISK_FILE`, `NETDEV`, config drive). MicroVM machine type cannot boot the stock Debian cloud kernel (`CONFIG_VIRTIO_MMIO=m` and `VIRTIO_MMIO_CMDLINE_DEVICES` not set) — see the notes at the bottom of the file.

## Gotchas

- VM disk is removed on exit unless `KEEP_DISK_FILE=1` (trap in `tap-vm.sh`).
- Injected SSH keys (both must exist or the script exits under `set -e`): `~/.ssh/id_ed25519.pub` and `~/.ssh/id_ed25519_ansible_user_development.pub`. `VM_ALLOW_PASSWORD=1` instead sets password `DEBIAN`; default locks the password.
- `VM_FORWARDS` and `PACKAGE_UPGRADE` are declared in `tap-vm.sh` but unused — no hostfwd is wired up.
- Build dependencies: `qemu-system-x86_64`, `qemu-img`, `xorriso`, `curl`, `sha512sum`; `wip/microvm.sh` also needs `jq` and `sudo` access (`modprobe nbd`, `qemu-nbd`, `mount`).
- Generated `network-config` / `user-data` / `meta-data` land in the cwd and are gitignored.

## Conventions

Bash only, no test/lint/build tooling. Follow the existing style: `set -euo pipefail`, GNU long options (`--flag=value`), `shopt -s nullglob` where globs are looped.