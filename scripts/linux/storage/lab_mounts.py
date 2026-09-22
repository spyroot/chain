#!/usr/bin/python3
"""Manage only chain's NFS/SMB block in Ubuntu fstab. Audience: human and agent."""

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

try:
    import yaml
except ImportError:
    print("BLOCKER: python3-yaml is missing", file=sys.stderr)
    print("SAFE_NEXT_STEP: install python3-yaml with toolchain_linux.sh.", file=sys.stderr)
    sys.exit(3)


BEGIN = "# BEGIN chain-managed lab mount:"
END = "# END chain-managed lab mount:"
LEGACY_BEGIN = "# BEGIN chain-managed lab mounts"
LEGACY_END = "# END chain-managed lab mounts"
DEFAULT_CONFIG = Path(__file__).resolve().parents[3] / "specs/linux/storage/lab_mounts.yaml"
KEY_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]*$")
HOST_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9.-]*$")
PATH_RE = re.compile(r"^/[A-Za-z0-9._/-]+$")
OPTIONS_RE = re.compile(r"^[A-Za-z0-9._=,-]+$")


class Blocked(Exception):
    def __init__(self, message, next_step=None):
        super().__init__(message)
        self.next_step = next_step or (
            "correct the YAML or local mount prerequisite, then rerun --dry-run"
        )


def clean_path(value, label):
    if not isinstance(value, str) or not PATH_RE.fullmatch(value):
        raise Blocked(f"{label} must be an absolute path without spaces")
    if value == "/" or any(part in (".", "..") for part in value.split("/")):
        raise Blocked(f"{label} cannot be / or contain dot path components")
    if "//" in value or value.endswith("/"):
        raise Blocked(f"{label} must use a normalized absolute path")
    return value


def mount_from_record(record, index):
    if not isinstance(record, dict):
        raise Blocked(f"mount {index} must be a YAML mapping")
    allowed = {"type", "host", "remote_path", "mount_point", "options", "credentials_file"}
    extra = set(record) - allowed
    if extra:
        raise Blocked(f"mount {index} has unsupported keys: {', '.join(sorted(extra))}")
    required = allowed - {"credentials_file"}
    missing = required - set(record)
    if missing:
        raise Blocked(f"mount {index} is missing: {', '.join(sorted(missing))}")

    kind = record["type"]
    if kind not in ("nfs", "smb"):
        raise Blocked(f"mount {index} type must be nfs or smb")
    host = record["host"]
    if not isinstance(host, str) or not HOST_RE.fullmatch(host):
        raise Blocked(f"mount {index} host must be an IPv4 address or DNS name")
    remote = clean_path(record["remote_path"], f"mount {index} remote_path")
    target = clean_path(record["mount_point"], f"mount {index} mount_point")
    options = record["options"]
    if not isinstance(options, str) or not OPTIONS_RE.fullmatch(options):
        raise Blocked(f"mount {index} options must be comma-separated fstab options")
    if any(opt.startswith(("password=", "username=", "credentials="))
           for opt in options.split(",")):
        raise Blocked(f"mount {index} credentials belong only in credentials_file")

    credentials = record.get("credentials_file")
    if kind == "nfs":
        if credentials is not None:
            raise Blocked(f"mount {index} NFS entry cannot use credentials_file")
        source = f"{host}:{remote}"
        # Let mount.nfs negotiate; an explicit vers= option in the spec pins it.
        fstype = "nfs"
    else:
        if credentials is None:
            raise Blocked(f"mount {index} SMB entry needs credentials_file")
        credentials = clean_path(credentials, f"mount {index} credentials_file")
        parts = remote.strip("/").split("/")
        source = f"//{host}/{parts[0]}"
        if len(parts) > 1:
            options += ",prefixpath=" + "/".join(parts[1:])
        options += f",credentials={credentials}"
        fstype = "cifs"

    return {"type": kind, "source": source, "target": target,
            "fstype": fstype, "options": options,
            "credentials_file": credentials}


def load_config(path):
    try:
        with path.open(encoding="utf-8") as stream:
            config = yaml.safe_load(stream)
    except (OSError, yaml.YAMLError) as exc:
        raise Blocked(f"cannot read valid YAML from {path}: {exc}") from exc
    if not isinstance(config, dict) or set(config) != {"version", "mounts"}:
        raise Blocked("YAML needs exactly version and mounts at the top level")
    if config["version"] != 1 or isinstance(config["version"], bool):
        raise Blocked("YAML version must be 1")
    if not isinstance(config["mounts"], dict) or not config["mounts"]:
        raise Blocked("mounts must be a nonempty YAML mapping keyed by mount name")
    mounts = {}
    for key, record in config["mounts"].items():
        if not isinstance(key, str) or not KEY_RE.fullmatch(key):
            raise Blocked("mount keys must contain only letters, digits, _ or -")
        mounts[key] = mount_from_record(record, key)
    targets = [mount["target"] for mount in mounts.values()]
    if len(targets) != len(set(targets)):
        raise Blocked("mount_point values must be unique")
    return mounts


def fstab_line(mount):
    return (f"{mount['source']} {mount['target']} {mount['fstype']} "
            f"{mount['options']} 0 0")


def block(key, mount):
    return "\n".join([f"{BEGIN} {key}", fstab_line(mount), f"{END} {key}"]) + "\n"


def replace_block(original, key, mount):
    lines = original.splitlines(keepends=True)
    if any(line.rstrip("\r\n") in (LEGACY_BEGIN, LEGACY_END) for line in lines):
        raise Blocked("fstab has a legacy shared lab-mount block; migrate it before keyed apply")
    start = f"{BEGIN} {key}"
    end = f"{END} {key}"
    starts = [i for i, line in enumerate(lines) if line.rstrip("\r\n") == start]
    ends = [i for i, line in enumerate(lines) if line.rstrip("\r\n") == end]
    if len(starts) != len(ends) or len(starts) > 1:
        raise Blocked(f"fstab has incomplete or duplicate markers for mount {key}")
    if starts and starts[0] >= ends[0]:
        raise Blocked(f"fstab markers for mount {key} are out of order")
    unmanaged = lines[:starts[0]] + lines[ends[0] + 1:] if starts else lines
    for line in unmanaged:
        fields = line.split()
        if fields and not fields[0].startswith("#") and len(fields) >= 2:
            if fields[1] == mount["target"]:
                raise Blocked(f"fstab already owns mount point {fields[1]} outside the managed block")
    if starts:
        return "".join(lines[:starts[0]]) + block(key, mount) + "".join(lines[ends[0] + 1:])
    separator = "" if not original else ("\n" if original.endswith("\n") else "\n\n")
    return original + separator + block(key, mount)


def atomic_fstab_write(path, content):
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent,
                                     prefix=".fstab.chain-", delete=False) as stream:
        temp_path = Path(stream.name)
        stream.write(content)
        stream.flush()
        os.fsync(stream.fileno())
    try:
        os.chmod(temp_path, 0o644)
        result = subprocess.run(["findmnt", "--verify", "--tab-file", str(temp_path)],
                                capture_output=True, text=True, check=False)
        if result.returncode:
            raise Blocked(f"findmnt rejected rendered fstab: {result.stderr.strip()}")
        os.replace(temp_path, path)
    finally:
        temp_path.unlink(missing_ok=True)


def preflight_mounts(mounts):
    for mount in mounts:
        target = Path(mount["target"])
        if target.is_symlink():
            raise Blocked(f"mount point is a symlink: {target}")
        if target.exists() and not target.is_dir():
            raise Blocked(f"mount point is not a directory: {target}")
        current = subprocess.run(["findmnt", "--mountpoint", str(target),
                                  "--noheadings", "--output", "SOURCE"],
                                 capture_output=True, text=True, check=False)
        if current.returncode == 0 and current.stdout.strip() != mount["source"]:
            raise Blocked(f"{target} is already mounted from another source")
        if current.returncode != 0 and target.exists() and any(target.iterdir()):
            raise Blocked(f"mount point is not empty: {target}")
        credentials = mount["credentials_file"]
        if credentials:
            credentials_path = Path(credentials)
            if not credentials_path.is_file():
                raise Blocked(f"SMB credentials file is missing: {credentials_path}")
            if credentials_path.stat().st_mode & 0o077:
                raise Blocked(f"SMB credentials file is readable by group/others: {credentials_path}")


def install_if_needed(mount):
    helper, package = (
        ("mount.nfs", "nfs-common") if mount["type"] == "nfs"
        else ("mount.cifs", "cifs-utils")
    )
    if shutil.which(helper):
        return False
    apt_get = shutil.which("apt-get")
    if not apt_get:
        raise Blocked(
            f"{helper} is missing and apt-get is unavailable",
            f"install {package} on this Ubuntu host, then rerun --apply",
        )

    env = dict(os.environ, DEBIAN_FRONTEND="noninteractive")
    for command, timeout in (
        ([apt_get, "update", "-qq"], 180),
        ([apt_get, "install", "-y", "-qq", "--no-install-recommends", package], 300),
    ):
        try:
            result = subprocess.run(
                command, capture_output=True, text=True, check=False,
                env=env, timeout=timeout,
            )
        except subprocess.TimeoutExpired as exc:
            raise Blocked(
                f"apt-get timed out while installing {package}",
                "inspect apt locks and repository connectivity, then rerun --apply",
            ) from exc
        if result.returncode:
            detail = (result.stderr or result.stdout).strip().splitlines()[-1:]
            raise Blocked(
                f"apt-get failed while installing {package}: "
                + (detail[0] if detail else f"exit {result.returncode}"),
                "inspect apt locks and repository connectivity, then rerun --apply",
            )
    if not shutil.which(helper):
        raise Blocked(
            f"{package} installed but {helper} is still unavailable",
            "check the helper path and rerun --apply",
        )
    print(f"INSTALLED_IF_NEEDED: {package}", file=sys.stderr)
    return True


def emit(args, state, mount=None, changed=False):
    public_mounts = [] if mount is None else [
        {"type": mount["type"], "source": mount["source"], "target": mount["target"]}
    ]
    if args.json:
        print(json.dumps({"schemaVersion": 1, "state": state,
                          "changed": changed, "mountKey": args.mount_key,
                          "mounts": public_mounts},
                         separators=(",", ":")))
    else:
        print(f"STATE: {state}")
        if state == "ready":
            print(block(args.mount_key, mount), end="")
        else:
            for item in public_mounts:
                print(f"{item['type']} {item['source']} -> {item['target']}")


def main():
    parser = argparse.ArgumentParser(
        prog="install_labmounts.sh",
        description="Persist one named NFS/SMB mount from a YAML spec in Ubuntu fstab. "
                    "Audience: human and agent. This does not mount it immediately.")
    parser.add_argument("mount_key", nargs="?", help="name of the mount under mounts: in the spec")
    parser.add_argument(
        "--config", type=Path, default=DEFAULT_CONFIG,
        help="mount spec (default: specs/linux/storage/lab_mounts.yaml in Chain)",
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--dry-run", action="store_true", help="validate and render only (default)")
    mode.add_argument("--apply", action="store_true",
                      help="update only this key's fstab block; mount target separately")
    parser.add_argument("--json", action="store_true", help="emit one JSON result")
    args = parser.parse_args()
    selected = None
    try:
        mounts = load_config(args.config)
        if not args.mount_key:
            raise Blocked("mount key is required; available keys: " + ", ".join(mounts))
        if args.mount_key not in mounts:
            raise Blocked(f"mount key {args.mount_key!r} not found; available keys: "
                          + ", ".join(mounts))
        selected = mounts[args.mount_key]
        if not args.apply:
            emit(args, "ready", selected)
            return 0
        if os.geteuid() != 0:
            raise Blocked(
                "--apply requires root",
                "rerun this command with sudo after reviewing --dry-run",
            )
        fstab = Path("/etc/fstab")
        original = fstab.read_text(encoding="utf-8")
        updated = replace_block(original, args.mount_key, selected)
        if updated == original:
            install_if_needed(selected)
            emit(args, "no-op", selected)
            return 0
        preflight_mounts([selected])
        install_if_needed(selected)
        Path(selected["target"]).mkdir(parents=True, exist_ok=True)
        atomic_fstab_write(fstab, updated)
        result = subprocess.run(["systemctl", "daemon-reload"], check=False,
                                capture_output=True, text=True)
        if result.returncode:
            atomic_fstab_write(fstab, original)
            subprocess.run(["systemctl", "daemon-reload"], check=False,
                           capture_output=True, text=True)
            raise Blocked(f"systemctl daemon-reload failed; fstab restored: {result.stderr.strip()}")
        emit(args, "configured", selected, changed=True)
        return 0
    except (Blocked, OSError) as exc:
        print(f"BLOCKER: {exc}", file=sys.stderr)
        next_step = exc.next_step if isinstance(exc, Blocked) else (
            "correct the local mount prerequisite, then rerun --dry-run"
        )
        print(f"SAFE_NEXT_STEP: {next_step}.", file=sys.stderr)
        emit(args, "blocked", selected)
        return 3


if __name__ == "__main__":
    sys.exit(main())
