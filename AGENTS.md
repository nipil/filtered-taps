# AGENTS.md

Launcher that attaches a cloud-init VM to a host-owned tap interface backed by a NAT/masquerade gateway. Not self-contained: the tap interface (`script=no`, `downscript=no`) and gateway IPs must already exist.

## Files

- `tap-vm.py` — main launcher (`qemu-system-x86_64`, KVM), Python 3 stdlib only. CLI flags with env-var fallback (flags win). Positional args: base qcow2 image; optional output disk (if omitted the disk is an **ephemeral** overlay in `~/.local/cache/sandbox/` with a random name, removed on exit; if provided the overlay is kept). Builds a cloud-init config drive in the repo cwd and uses no port forwarding (VM is reached directly via the tap network). Run `./tap-vm.py --help` for the full reference.
- `get-debian-images.sh` — downloads a Debian cloud image to `./images`, SHA512-verified; the final filename appears only after verification passes. Defaults: `trixie genericcloud amd64 qcow2`.

## `tap-vm.py` parameter map

CLI flag → env fallback → default:

| Flag | Env | Default |
| --- | --- | --- |
| `<base-image>` | `VM_IMAGE_FILE` | required |
| `[output-disk]` | `VM_DISK_FILE` | ephemeral (`~/.local/cache/sandbox/`, random name) |
| `--tap-if` | `VM_TAP_IF` | required |
| `--gw-ip` | `VM_GW_IP` | required with `--guest-ip` |
| `--guest-ip` | `VM_GUEST_IP` | absent → DHCP4 |
| `--net-suffix` | `VM_NET_SUFFIX` | required with `--guest-ip` |
| `--dns` (repeatable) | `VM_DNS` (comma list) | `8.8.8.8,1.1.1.1` |
| `--net-if` | `VM_NET_IF` | `ens3` |
| `--name` | `VM_NAME` | `sandbox` |
| `--domain` | `VM_DOMAIN` | `lan` |
| `--size` (M/G/T) | `VM_SIZE` | `4G` |
| `--ram` (M/G/T) | `VM_RAM` | `2G` |
| `--cpus` | `VM_CPU` | `1` |
| `--qemu` | `VM_QEMU` | `qemu-system-x86_64` |
| `--machine` | `VM_MACHINE` | `pc,graphics=off,i8042=off,usb=off,smbus=off,sata=off,pit=off,hpet=off,pic=off,vmport=off` |
| `--ssh-keys` (repeatable) | `VM_AUTH_KEYS` (comma list) | all `.pub` in `~/.ssh/` |
| `--upgrade` | `VM_UPGRADE` | `false` |
| env only | `VM_ACCOUNT` (`user:password`) | unset → user `debian`, password locked |

## Gotchas

- `--size`/`--ram` only accept `[0-9]+[MGT]` units (mega/giga/tera octets).
- `--qemu` is a name or path (checked with `shutil.which`); `--machine` is passed verbatim to `-machine`.
- Static mode needs `--guest-ip` + `--gw-ip` + `--net-suffix` together; `--gw-ip`/`--net-suffix` alone are ignored (DHCP mode).
- `--gw-ip` and `--guest-ip` may be IP literals or names resolvable via DNS/`/etc/hosts`; they are resolved to an IPv4 address before being written to the cloud-init network config (IPv6 is rejected).
- Injected SSH keys: default is every `*.pub` in `~/.ssh/`. SSH keys are optional when `VM_ACCOUNT` enables password login; at least one of (password login, SSH keys) must be possible, otherwise the script errors ("no way to log in"). Both the `debian` user and `root` get them.
- Password auth only activates when `VM_ACCOUNT=user:password` is set; format is validated (must contain a `:`), otherwise default user `debian` with locked password.
- Persistent disks are removed before being recreated (existing file is deleted first); ephemeral disks are removed on exit, error or not.
- `upgrade` is wired into cloud-init (`package_update`/`package_upgrade`).
- Exit code: on a clean QEMU shutdown the script returns the QEMU return code; validation/usage errors print `ERROR: ...` on stderr and exit 1 (via `safe_main` catching `AppError`).

## Conventions

Python 3.10+, stdlib only, `#!/usr/bin/env python3`, argparse long options, fully typed, no external deps or test tooling.

- Errors are `AppError` exceptions raised from the logic (no `sys.exit` outside `safe_main()`); `safe_main()` wraps `main()` in `try/except/finally`, prints `ERROR: ...` to stderr, flushes stdout/stderr, and is the single place that calls `sys.exit`. `main()` returns the QEMU return code.
- EAFP instead of look-before-you-leap: file operations are guarded with `try/except FileNotFoundError`/`OSError`, and internal causes are hidden with `raise ... from None`.
- Temporary files/dirs use `tempfile` context managers (`TemporaryDirectory`, `NamedTemporaryFile`); the ephemeral disk lifecycle is a `@contextmanager` whose cleanup runs in `finally`.
- Helper subprocesses (`qemu-img`, `xorriso`) run with `check=True`; the final QEMU run is `check=False` and its returncode becomes the exit code.

Bash files keep the existing style: `set -euo pipefail`, GNU long options (`--flag=value`), `shopt -s nullglob` where globs are looped.

Generated `network-config` / `user-data` / `meta-data` land in the cwd and are gitignored.
