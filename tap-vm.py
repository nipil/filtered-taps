#!/usr/bin/env python3

import argparse
import ipaddress
import os
import re
import shutil
import subprocess
import socket
import sys
import tempfile
from contextlib import contextmanager
from pathlib import Path
from typing import Iterator

SIZE_RE: re.Pattern = re.compile(r"^[0-9]+[MGT]$")

QEMU_DEFAULT: str = "qemu-system-x86_64"
VM_NAME_DEFAULT: str = "sandbox"
DOMAIN_DEFAULT: str = "lan"
SIZE_DEFAULT: str = "4G"
RAM_DEFAULT: str = "2G"
CPUS_DEFAULT: str = "1"
NET_IF_DEFAULT: str = "ens3"
USER_DEFAULT: str = "debian"
DNS_DEFAULT: list[str] = ["8.8.8.8", "1.1.1.1"]
SSH_KEYS_GLOB: str = "*.pub"
MACHINE_DEFAULT: str = (
    "pc,graphics=off,i8042=off,usb=off,smbus=off,sata=off,pit=off,hpet=off,pic=off,vmport=off"
)


class AppError(Exception):
    pass


def write_file(path: Path, content: str) -> None:
    with path.open("w", encoding="utf-8") as fh:
        fh.write(content)


def pick(
    cli_value: str | None,
    env_name: str,
    default: str | None = None,
) -> str | None:
    if cli_value is not None:
        return cli_value
    env_value = os.environ.get(env_name)
    if env_value is not None:
        return env_value
    return default


def comma_list(value: str) -> list[str]:
    return [item.strip() for item in value.split(",") if item.strip()]


def env_true(env_name: str) -> bool:
    value = os.environ.get(env_name)
    return value.lower() in ("1", "true", "yes", "on") if value else False


def remove_ephemeral_disk(disk_path: Path) -> None:
    try:
        disk_path.unlink()
        print(f"Removed {disk_path}")
    except FileNotFoundError:
        pass


@contextmanager
def vm_disk(
    persistent: bool,
    disk_arg: str | None,
    vm_name: str,
) -> Iterator[Path]:
    if persistent and disk_arg is not None:
        disk_path: Path = Path(disk_arg).expanduser()
        try:
            disk_path.unlink()
            print(f"Removed {disk_path}")
        except FileNotFoundError:
            pass
        yield disk_path
    else:
        sandbox_dir: Path = Path.home() / ".local" / "cache" / "sandbox"
        sandbox_dir.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(
            dir=str(sandbox_dir),
            prefix=f"{vm_name}-",
            suffix=".qcow2",
        ) as tmp:
            disk_path = Path(tmp.name)
        try:
            yield disk_path
        finally:
            remove_ephemeral_disk(disk_path)


def validate_size(value: str, label: str) -> str:
    if not SIZE_RE.match(value):
        raise AppError(
            f"{label}: invalid size '{value}' (use a size like 4G, 512M or 2T)",
        )
    return value


def resolve_addr(value: str | None, label: str, required: bool) -> str | None:
    if not value:
        if required:
            raise AppError(f"{label}: is required")
        return None
    try:
        ip: ipaddress.IPv4Address | ipaddress.IPv6Address = ipaddress.ip_address(value)
    except ValueError:
        pass
    else:
        if ip.version == 4:
            return value
        raise AppError(f"{label}: expected an IPv4 address, got '{value}'") from None
    try:
        resolved: str = socket.gethostbyname(value)
    except socket.gaierror:
        raise AppError(f"{label}: cannot resolve '{value}'") from None
    return resolved


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="tap-vm.py",
        usage="%(prog)s [OPTIONS] <base-image> [output-disk]",
        description="Create a cloud-init VM attached to a host-owned tap interface.",
        formatter_class=argparse.RawTextHelpFormatter,
    )
    parser.add_argument(
        "base_image",
        metavar="<base-image>",
        nargs="?",
        help="Path to the base qcow2 image [env: VM_IMAGE_FILE]",
    )
    parser.add_argument(
        "output_disk",
        metavar="[output-disk]",
        nargs="?",
        help="Path for the output VM disk (qcow2 overlay)\n"
        "If omitted: ephemeral disk in ~/.local/cache/sandbox/\n"
        "If provided: persistent disk (kept on exit) [env: VM_DISK_FILE]",
    )
    parser.add_argument(
        "--tap-if",
        metavar="NAME",
        help="Tap interface name [env: VM_TAP_IF]",
    )
    parser.add_argument(
        "--gw-ip",
        "--gateway-ip",
        metavar="ADDR",
        help="Gateway IP address or hostname, resolved if needed [env: VM_GW_IP]",
    )
    parser.add_argument(
        "--guest-ip",
        metavar="ADDR",
        help="Static guest IP or hostname, resolved if needed; absent enables DHCP4 [env: VM_GUEST_IP]",
    )
    parser.add_argument(
        "--net-suffix",
        metavar="N",
        help="Network suffix / CIDR (e.g. 30), required with --guest-ip [env: VM_NET_SUFFIX]",
    )
    parser.add_argument(
        "--dns",
        metavar="ADDR",
        action="append",
        help=f"DNS server (repeatable) [env: VM_DNS] [default: {','.join(DNS_DEFAULT)}]",
    )
    parser.add_argument(
        "--net-if",
        metavar="NAME",
        help=f"Cloud-init interface name [env: VM_NET_IF] [default: {NET_IF_DEFAULT}]",
    )
    parser.add_argument(
        "--name",
        metavar="NAME",
        help=f"VM hostname [env: VM_NAME] [default: {VM_NAME_DEFAULT}]",
    )
    parser.add_argument(
        "--domain",
        metavar="DOMAIN",
        help=f"Domain for FQDN [env: VM_DOMAIN] [default: {DOMAIN_DEFAULT}]",
    )
    parser.add_argument(
        "--size",
        metavar="SIZE",
        help=f"Disk size (M/G/T) [env: VM_SIZE] [default: {SIZE_DEFAULT}]",
    )
    parser.add_argument(
        "--ram",
        metavar="SIZE",
        help=f"Memory (M/G/T) [env: VM_RAM] [default: {RAM_DEFAULT}]",
    )
    parser.add_argument(
        "--cpus",
        metavar="N",
        help=f"Number of vCPUs [env: VM_CPU] [default: {CPUS_DEFAULT}]",
    )
    parser.add_argument(
        "--qemu",
        metavar="PATH",
        help=f"qemu-system binary, name or path [env: VM_QEMU] [default: {QEMU_DEFAULT}]",
    )
    parser.add_argument(
        "--machine",
        metavar="SPEC",
        help="QEMU machine specification [env: VM_MACHINE]\n"
        f"[default: {MACHINE_DEFAULT}]",
    )
    parser.add_argument(
        "--ssh-keys",
        metavar="FILE",
        action="append",
        dest="ssh_keys",
        help=f"SSH public key (repeatable) [env: VM_AUTH_KEYS]\n"
        f"Default: all {SSH_KEYS_GLOB} files in ~/.ssh/\n"
        "Optional if VM_ACCOUNT enables password login",
    )
    parser.add_argument(
        "--upgrade",
        action="store_const",
        const=True,
        default=None,
        help="Run apt upgrade in cloud-init [env: VM_UPGRADE] [default: false]",
    )
    return parser


def resolve_ssh_keys(args: argparse.Namespace) -> list[str]:
    if args.ssh_keys:
        key_files: list[str] = args.ssh_keys
    elif os.environ.get("VM_AUTH_KEYS"):
        key_files = comma_list(os.environ["VM_AUTH_KEYS"])
    else:
        key_files = [
            str(path) for path in sorted(Path.home().glob(f".ssh/{SSH_KEYS_GLOB}"))
        ]
    keys: list[str] = []
    for key_file in key_files:
        key_path = Path(key_file).expanduser()
        try:
            with key_path.open("r", encoding="utf-8") as fh:
                for line in fh:
                    stripped = line.strip()
                    if stripped and not stripped.startswith("#"):
                        keys.append(stripped)
        except FileNotFoundError:
            raise AppError(f"SSH public key file not found: {key_path}") from None
    return keys


def resolve_dns(args: argparse.Namespace) -> list[str]:
    if args.dns:
        servers: list[str] = args.dns
    elif os.environ.get("VM_DNS"):
        servers = comma_list(os.environ["VM_DNS"])
    else:
        servers = list(DNS_DEFAULT)
    for server in servers:
        try:
            ipaddress.ip_address(server)
        except ValueError:
            raise AppError(f"DNS: invalid IP address '{server}'") from None
    return servers


def build_network_config(
    net_if: str,
    guest_ip: str | None,
    gw_ip: str | None,
    net_suffix: int | None,
    dns: list[str],
) -> str:
    lines: list[str] = ["version: 2", "ethernets:", f"  {net_if}:"]
    if guest_ip and gw_ip and net_suffix is not None:
        lines += [
            "    dhcp4: false",
            "    dhcp6: false",
            "    addresses:",
            f"      - {guest_ip}/{net_suffix}",
            "    routes:",
            "      - to: default",
            f"        via: {gw_ip}",
        ]
    else:
        lines += ["    dhcp4: true", "    dhcp6: false"]
    lines += ["    nameservers:", "      addresses:"]
    lines += [f"        - {server}" for server in dns]
    return "\n".join(lines) + "\n"


def build_user_data(
    vm_name: str,
    domain: str,
    username: str,
    keys: list[str],
    lock_passwd: bool,
    password: str | None,
    upgrade: bool,
) -> str:
    lines: list[str] = [
        "#cloud-config",
        f"hostname: {vm_name}",
        f"fqdn: {vm_name}.{domain}",
        "",
        "users:",
        f"  - name: {username}",
        "    gecos: Debian user",
        "    sudo: ALL=(ALL) NOPASSWD:ALL",
        "    shell: /bin/bash",
        f"    lock_passwd: {'true' if lock_passwd else 'false'}",
    ]
    if not lock_passwd and password is not None:
        lines.append(f"    plain_text_passwd: {password}")
    if keys:
        lines.append("    ssh_authorized_keys:")
        lines += [f"      - {key}" for key in keys]
    lines.append("  - name: root")
    if keys:
        lines.append("    ssh_authorized_keys:")
        lines += [f"      - {key}" for key in keys]
    if upgrade:
        lines += ["", "package_update: true", "package_upgrade: true"]
    return "\n".join(lines) + "\n"


def build_metadata(vm_name: str) -> str:
    return (
        "{\n"
        f'  "instance-id": "{vm_name}",\n'
        f'  "local-hostname": "{vm_name}"\n'
        "}\n"
    )


def main() -> int:
    args: argparse.Namespace = build_parser().parse_args()

    base_image_raw: str | None = pick(args.base_image, "VM_IMAGE_FILE")
    if not base_image_raw:
        raise AppError("input qcow2 base image path missing")
    base_image: Path = Path(base_image_raw).expanduser()
    try:
        # fail early
        with base_image.open("rb"):
            pass
    except OSError:
        raise AppError(f"base image not found or unreadable: {base_image}") from None

    disk_arg: str | None = pick(args.output_disk, "VM_DISK_FILE")
    persistent: bool = disk_arg is not None

    tap_if_raw: str | None = pick(args.tap_if, "VM_TAP_IF")
    if not tap_if_raw:
        raise AppError("tap interface name is required (--tap-if or VM_TAP_IF)")
    tap_if: str = tap_if_raw

    guest_ip: str | None = resolve_addr(
        pick(args.guest_ip, "VM_GUEST_IP"),
        "guest IP",
        False,
    )
    if guest_ip:
        gw_ip_raw: str | None = resolve_addr(
            pick(args.gw_ip, "VM_GW_IP"),
            "gateway IP",
            True,
        )
        gw_ip: str | None = gw_ip_raw
        net_suffix_raw: str | None = pick(args.net_suffix, "VM_NET_SUFFIX")
        if net_suffix_raw is None:
            raise AppError("--net-suffix is required when --guest-ip is set")
        try:
            net_suffix: int | None = int(net_suffix_raw)
        except ValueError:
            raise AppError(
                f"network suffix: invalid value '{net_suffix_raw}'",
            ) from None
        if not 0 <= net_suffix <= 32:
            raise AppError(
                f"network suffix: expected a CIDR length between 0 and 32, got {net_suffix}",
            )
    else:
        gw_ip = None
        net_suffix = None

    vm_name_raw: str | None = pick(args.name, "VM_NAME", VM_NAME_DEFAULT)
    vm_name: str = vm_name_raw or VM_NAME_DEFAULT
    domain_raw: str | None = pick(args.domain, "VM_DOMAIN", DOMAIN_DEFAULT)
    domain: str = (domain_raw or DOMAIN_DEFAULT).lstrip(".")

    size_raw: str | None = pick(args.size, "VM_SIZE", SIZE_DEFAULT)
    vm_size: str = validate_size(size_raw or SIZE_DEFAULT, "disk size")
    ram_raw: str | None = pick(args.ram, "VM_RAM", RAM_DEFAULT)
    vm_ram: str = validate_size(ram_raw or RAM_DEFAULT, "memory")

    cpus_raw: str | None = pick(args.cpus, "VM_CPU", CPUS_DEFAULT)
    try:
        cpus: int = int(cpus_raw or CPUS_DEFAULT)
    except ValueError:
        raise AppError(f"cpus: invalid value '{cpus_raw}'") from None
    if cpus < 1:
        raise AppError(f"cpus: must be at least 1, got {cpus}")

    net_if_raw: str | None = pick(args.net_if, "VM_NET_IF", NET_IF_DEFAULT)
    net_if: str = net_if_raw or NET_IF_DEFAULT
    if not net_if:
        raise AppError("network interface name must not be empty")

    qemu_bin_raw: str | None = pick(args.qemu, "VM_QEMU", QEMU_DEFAULT)
    qemu_bin: str = qemu_bin_raw or QEMU_DEFAULT
    machine_raw: str | None = pick(args.machine, "VM_MACHINE", MACHINE_DEFAULT)
    machine: str = machine_raw or MACHINE_DEFAULT

    for tool in (qemu_bin, "qemu-img", "xorriso"):
        if not shutil.which(tool):
            raise AppError(f"required tool not found: {tool}")

    dns: list[str] = resolve_dns(args)

    account: str | None = os.environ.get("VM_ACCOUNT")
    if account:
        if ":" not in account:
            raise AppError(
                f"VM_ACCOUNT: expected '<username>:<password>', got '{account}'",
            )
        username, password = account.split(":", 1)
        lock_passwd: bool = False
    else:
        username = USER_DEFAULT
        password = None
        lock_passwd = True

    ssh_keys: list[str] = resolve_ssh_keys(args)
    if lock_passwd and not ssh_keys:
        raise AppError(
            "no way to log in: no SSH keys and password login disabled, "
            "set VM_ACCOUNT=<username>:<password> or provide --ssh-keys/VM_AUTH_KEYS",
        )

    upgrade: bool = args.upgrade if args.upgrade is not None else env_true("VM_UPGRADE")

    with tempfile.TemporaryDirectory(suffix="-config-drive") as config_dir, vm_disk(
        persistent,
        disk_arg,
        vm_name,
    ) as disk_path:
        subprocess.run(
            [
                "qemu-img",
                "create",
                "-f",
                "qcow2",
                "-b",
                str(base_image),
                "-F",
                "qcow2",
                str(disk_path),
                vm_size,
            ],
            check=True,
        )

        cloudinit_dir: Path = Path(config_dir) / "configdrive"
        cloudinit_dir.mkdir(parents=True)

        network_config: str = build_network_config(
            net_if,
            guest_ip,
            gw_ip,
            net_suffix,
            dns,
        )
        user_data: str = build_user_data(
            vm_name,
            domain,
            username,
            ssh_keys,
            lock_passwd,
            password,
            upgrade,
        )
        metadata: str = build_metadata(vm_name)

        cloudinit_files: list[tuple[str, str]] = [
            ("network-config", network_config),
            ("user-data", user_data),
            ("meta-data", metadata),
        ]
        for filename, content in cloudinit_files:
            write_file(Path.cwd() / filename, content)
            write_file(cloudinit_dir / filename, content)

        with tempfile.NamedTemporaryFile(
            dir=config_dir,
            prefix="configdrive-",
            suffix=".iso",
        ) as iso_tmp:
            configdrive_iso: Path = Path(iso_tmp.name)
        subprocess.run(
            [
                "xorriso",
                "-as",
                "mkisofs",
                "-o",
                str(configdrive_iso),
                "-V",
                "cidata",
                "-J",
                "-r",
                str(cloudinit_dir),
            ],
            check=True,
        )

        netdev: str = f"tap,id=net0,ifname={tap_if},script=no,downscript=no"

        print(
            f"Running VM {vm_name} ... Press ctrl-a then c to get into qemu monitor, then quit to exit."
        )

        result: subprocess.CompletedProcess[bytes] = subprocess.run(
            [
                qemu_bin,
                "-machine",
                machine,
                "-cpu",
                "host",
                "-m",
                vm_ram,
                "-smp",
                str(cpus),
                "-enable-kvm",
                "-drive",
                f"file={disk_path},format=qcow2,if=virtio",
                "-drive",
                f"file={configdrive_iso},format=raw,if=virtio,read-only=on",
                "-netdev",
                netdev,
                "-device",
                "virtio-net-pci,netdev=net0",
                "-display",
                "none",
                "-serial",
                "mon:stdio",
            ]
        )
        return result.returncode


def safe_main() -> None:
    exit_code: int = 1
    try:
        exit_code = main()
    except AppError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
    finally:
        sys.stdout.flush()
        sys.stderr.flush()
    sys.exit(exit_code)


if __name__ == "__main__":
    safe_main()
