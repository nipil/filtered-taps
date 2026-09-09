# filtered-taps

Tools to attach cloud-init QEMU VMs to host-owned tap interfaces backed by a
NAT/masquerade gateway.

## `tap-vm.py`

Attaches a cloud-init VM to a host-owned tap interface. Not self-contained: the
tap interface (`script=no`, `downscript=no`) and gateway network must already
exist.

```sh
./tap-vm.py [OPTIONS] <base-image> [output-disk]
```

Run `./tap-vm.py --help` for the full option reference.

### Disk handling

- Without `[output-disk]` the VM disk is **ephemeral**: a qcow2 overlay is
  created in `~/.local/cache/sandbox/` with a random name and removed on exit,
  even if the run fails.
- With `[output-disk]` the disk is **persistent**: a qcow2 overlay created at
  the given path and kept on exit. An existing file at that path is removed
  before being recreated.

### Networking

- `--guest-ip` set → static IP (requires `--gw-ip` and `--net-suffix`).
- `--guest-ip` absent → DHCP4 is enabled in the guest.
- `--gw-ip` / `--guest-ip` accept IP literals or names resolvable via DNS or
  `/etc/hosts`; they are resolved to IPv4 before being written to the guest
  network config.

Every option also has an environment fallback; CLI flags take precedence:

| Option | Env var | Default |
| --- | --- | --- |
| `<base-image>` | `VM_IMAGE_FILE` | — |
| `[output-disk]` | `VM_DISK_FILE` | ephemeral |
| `--tap-if` | `VM_TAP_IF` | — |
| `--gw-ip` | `VM_GW_IP` | — |
| `--guest-ip` | `VM_GUEST_IP` | DHCP mode |
| `--net-suffix` | `VM_NET_SUFFIX` | — |
| `--dns` (repeatable) | `VM_DNS` (comma list) | `8.8.8.8,1.1.1.1` |
| `--net-if` | `VM_NET_IF` | `ens3` |
| `--name` | `VM_NAME` | `sandbox` |
| `--domain` | `VM_DOMAIN` | `lan` |
| `--size` (M/G/T) | `VM_SIZE` | `4G` |
| `--ram` (M/G/T) | `VM_RAM` | `2G` |
| `--cpus` | `VM_CPU` | `1` |
| `--qemu` | `VM_QEMU` | `qemu-system-x86_64` |
| `--machine` | `VM_MACHINE` | `pc,graphics=off, ...` |
| `--ssh-keys` (repeatable) | `VM_AUTH_KEYS` (comma list) | all `~/.ssh/*.pub` |
| `--upgrade` | `VM_UPGRADE` | `false` |
| — | `VM_ACCOUNT` (`user:password`) | not set → `debian` + locked |

`VM_ACCOUNT` enables password authentication for the given user when present.
At least one login path must be possible: `VM_ACCOUNT` (password login) and/or
SSH keys, otherwise the script errors.

### Dependencies

`python3` (3.10+, stdlib only), `qemu-system-x86_64`, `qemu-img`, `xorriso`. The
QEMU binary and `-machine` spec can be overridden with `--qemu` / `--machine`.

## `get-debian-images.sh`

Downloads a Debian cloud image to `./images`, SHA512-verified; the final
filename appears only after verification passes. Defaults:
`trixie genericcloud amd64 qcow2`.
