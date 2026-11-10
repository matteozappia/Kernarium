#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Verify the kernel-less LineageOS recovery partition and its compressed ramdisk."""

from __future__ import annotations

__import__("sys").dont_write_bytecode = True

import argparse
import gzip
import io
import re
import stat
import struct
from pathlib import Path, PurePosixPath

import android_image
import selinux_policy


MAX_RAMDISK_SIZE = 256 * 1024 * 1024
LZ4_LEGACY_MAGIC = b"\x02\x21\x4c\x18"
LZ4_LEGACY_BLOCK_LIMIT = 8 * 1024 * 1024
REQUIRED_PATHS = {
    "init",
    "prop.default",
    "sepolicy",
    "system/bin/adbd",
    "system/bin/e2fsck",
    "system/bin/kernarium_addons.sh",
    "system/bin/mke2fs",
    "system/bin/recovery",
    "system/bin/resize2fs",
    "system/bin/tune2fs",
    "system/etc/recovery.fstab",
    "system/lib64/librecovery_ui.so",
    "system/lib64/librecovery_ui_ext.so",
}
# The product overlay's recovery script (overlay/config/init.recovery.rc) replaces
# Cuttlefish's init.recovery.cutf_cvm.rc, which would put the Cuttlefish script
# back without a message; the Cuttlefish script is kept as the one it imports.
RECOVERY_SCRIPT = "init.recovery.cutf_cvm.rc"
RECOVERY_SCRIPT_IMPORT = "init.recovery.cuttlefish.rc"
# Recovery draws its UI at the density it reads from ro.sf.lcd_density, and the
# host's ro.boot.lcd_density is vendor-private, so the script publishes it.
DENSITY_TRIGGER = "on early-init && property:ro.boot.lcd_density=*"
DENSITY_COMMAND = "setprop ro.sf.lcd_density ${ro.boot.lcd_density}"


# The recovery UI gives eth0 its SLiRP address itself, with SIOCSIFADDR and SIOCSIFNETMASK on a
# UDP socket (overlay/recovery). The recovery domain's policy is the ramdisk's own /sepolicy: the
# stock policy gives it no UDP socket, so the UI's socket() failed with EACCES ("Failed to open
# socket: Permission denied" on the screen) and eth0 kept no IPv4 address. The product grants
# the socket and exactly those two ioctls (overlay/sepolicy/vendor/recovery.te).
RECOVERY_DOMAIN = "recovery"
ADDRESS_IOCTLS = {0x8916, 0x891C}


# The product's own recovery artwork: the device overlay's recovery/res/images, which the build copies
# over the stock resources of the ramdisk's /res/images. Every file there must reach the ramdisk
# unchanged, and the ramdisk must hold no other progress animation frame than the product's.
ART_DIRECTORY = "overlay/recovery/res/images"
ART_REQUIRED = ("fastbootd.png", "logo_image.png", "logo_image_switch.png", "loop00000.png")
ART_FRAME = re.compile(r"loop[0-9]{5}\.png")


class VerificationError(ValueError):
    pass


def fail(message: str) -> None:
    raise VerificationError(message)


def regular_file(path: Path, label: str) -> Path:
    if path.is_symlink() or not path.is_file():
        fail(f"{label} must be a regular non-symlink file: {path}")
    return path.resolve()


def lz4_block(block: bytes, limit: int) -> bytes:
    """Decode one LZ4 block into at most `limit` bytes."""
    output = bytearray()
    position, length = 0, len(block)
    try:
        while position < length:
            token = block[position]
            position += 1
            literals = token >> 4
            if literals == 15:
                while True:
                    extra = block[position]
                    position += 1
                    literals += extra
                    if extra != 255:
                        break
            if position + literals > length:
                fail("LZ4 literal run exceeds its block")
            output += block[position:position + literals]
            position += literals
            if position == length:
                break
            offset = block[position] | (block[position + 1] << 8)
            position += 2
            if offset == 0 or offset > len(output):
                fail("LZ4 match offset is outside the decoded data")
            match = token & 15
            if match == 15:
                while True:
                    extra = block[position]
                    position += 1
                    match += extra
                    if extra != 255:
                        break
            match += 4
            start = len(output) - offset
            if offset >= match:
                output += output[start:start + match]
            else:
                pattern = bytes(output[start:])
                output += (pattern * (match // offset + 1))[:match]
            if len(output) > limit:
                fail("LZ4 block exceeds its size limit")
    except IndexError:
        fail("LZ4 block is truncated")
    if len(output) > limit:
        fail("LZ4 block exceeds its size limit")
    return bytes(output)


def decompress_lz4_legacy(payload: bytes) -> bytes:
    """Decode the LZ4 legacy frame that Android's recovery ramdisk uses."""
    if not payload.startswith(LZ4_LEGACY_MAGIC):
        fail("recovery ramdisk is not an LZ4 legacy frame")
    result = bytearray()
    position = 0
    while position < len(payload):
        word = payload[position:position + 4]
        if len(word) != 4:
            fail("LZ4 legacy frame has trailing bytes")
        position += 4
        if word == LZ4_LEGACY_MAGIC:
            continue
        size = struct.unpack("<I", word)[0]
        if size == 0 or position + size > len(payload):
            fail("LZ4 legacy block exceeds the ramdisk")
        result += lz4_block(payload[position:position + size], LZ4_LEGACY_BLOCK_LIMIT)
        position += size
        if len(result) > MAX_RAMDISK_SIZE:
            fail("decompressed recovery ramdisk exceeds the size limit")
    return bytes(result)


def decompress_ramdisk(payload: bytes) -> bytes:
    if payload.startswith(LZ4_LEGACY_MAGIC):
        result = decompress_lz4_legacy(payload)
    elif payload.startswith(b"\x1f\x8b"):
        try:
            with gzip.GzipFile(fileobj=io.BytesIO(payload), mode="rb") as archive:
                result = archive.read(MAX_RAMDISK_SIZE + 1)
        except (OSError, EOFError) as error:
            fail(f"cannot decompress recovery ramdisk: {error}")
    else:
        fail("recovery ramdisk is neither an LZ4 legacy frame nor gzip")
    if not result or len(result) > MAX_RAMDISK_SIZE:
        fail("decompressed recovery ramdisk size is invalid")
    return result


def verify_elf(name: str, payload: bytes) -> bool:
    if not payload.startswith(android_image.ELF_MAGIC):
        return False
    android_image.check_aarch64_elf_header(name, payload, VerificationError)
    program_offset = struct.unpack_from("<Q", payload, 32)[0]
    entry_size, entry_count = struct.unpack_from("<HH", payload, 54)
    if program_offset + entry_size * entry_count > len(payload):
        fail(f"target ELF program headers are malformed: {name}")
    for segment in android_image.program_headers(payload):
        if segment.offset + segment.file_size > len(payload):
            fail(f"target ELF segment exceeds its payload: {name}")
    if android_image.check_load_alignment(name, payload, VerificationError) == 0:
        fail(f"target ELF contains no load segment: {name}")
    return True


def elf_needed(name: str, payload: bytes) -> set[str]:
    needed = android_image.elf_needed(name, payload, VerificationError)
    if any(not library or "/" in library or library in (".", "..") for library in needed):
        fail(f"target ELF has an unsafe DT_NEEDED name: {name}")
    return needed


def product_art(android_root: Path) -> dict[str, bytes]:
    """The artwork the device overlay supplies to recovery, by file name."""
    directory = android_root / ART_DIRECTORY
    art = {}
    if directory.is_dir():
        for path in sorted(directory.iterdir()):
            art[path.name] = regular_file(path, "product recovery artwork").read_bytes()
    absent = [name for name in ART_REQUIRED if name not in art]
    if absent:
        fail(f"{ART_DIRECTORY} lacks the product's recovery artwork: {absent}")
    return art


def verify_art(entries: dict[str, android_image.NewcEntry], art: dict[str, bytes]) -> None:
    for name, payload in art.items():
        entry = entries.get(f"res/images/{name}")
        if entry is None:
            fail(f"recovery ramdisk lacks the product's artwork res/images/{name}")
        if entry.payload != payload:
            fail(f"recovery ramdisk's res/images/{name} is not the product's artwork")
    frames = {
        PurePosixPath(name).name
        for name in entries
        if name.startswith("res/images/") and ART_FRAME.fullmatch(name[len("res/images/"):])
    }
    foreign = sorted(frames - art.keys())
    if foreign:
        fail(f"recovery ramdisk carries progress animation frames the product does not supply: {foreign}")


def check_recovery_script(script: bytes) -> None:
    """The script imports Cuttlefish's and publishes the host density before the UI starts."""
    imports: list[str] = []
    sections: dict[str, list[str]] = {}
    section = None
    for raw in script.decode("utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if raw[0].isspace():
            if section is not None:
                sections[section].append(line)
        elif line.startswith("import "):
            imports.append(line.split(None, 1)[1].lstrip("/"))
            section = None
        else:
            section = line
            sections.setdefault(section, [])
    if RECOVERY_SCRIPT_IMPORT not in imports:
        fail(f"recovery script does not import {RECOVERY_SCRIPT_IMPORT}")
    if DENSITY_COMMAND not in sections.get(DENSITY_TRIGGER, []):
        fail(f"recovery script does not run '{DENSITY_COMMAND}' at '{DENSITY_TRIGGER}'")


def check_recovery_policy(policy_bytes: bytes) -> None:
    """The recovery domain may open the UDP socket the UI addresses eth0 with, and no more."""
    try:
        policy = selinux_policy.SelinuxPolicy(policy_bytes)
    except selinux_policy.PolicyError as error:
        fail(f"recovery sepolicy is not a readable kernel policy: {error}")
    for target_class, wanted in (("udp_socket", {"create", "ioctl"}), ("capability", {"net_admin"})):
        held = policy.permissions(RECOVERY_DOMAIN, RECOVERY_DOMAIN, target_class)
        if not wanted <= held:
            fail(
                f"recovery policy does not let the {RECOVERY_DOMAIN} domain {sorted(wanted - held)} "
                f"on {target_class}: the UI could not give eth0 its address"
            )
    commands = policy.ioctls(RECOVERY_DOMAIN, RECOVERY_DOMAIN, "udp_socket")
    if commands != ADDRESS_IOCTLS:
        fail(
            f"recovery policy lets the {RECOVERY_DOMAIN} domain issue the ioctls "
            f"{sorted(map(hex, commands))} on a UDP socket, not exactly "
            f"{sorted(map(hex, ADDRESS_IOCTLS))}"
        )


def verify_entries(
    entries: dict[str, android_image.NewcEntry], expected_fstab: bytes, expected_script: bytes,
    art: dict[str, bytes],
) -> int:
    missing = sorted((REQUIRED_PATHS | {RECOVERY_SCRIPT, RECOVERY_SCRIPT_IMPORT}) - entries.keys())
    if missing:
        fail(f"recovery ramdisk is missing required paths: {missing}")
    if entries[RECOVERY_SCRIPT].payload != expected_script:
        fail(f"recovery {RECOVERY_SCRIPT} differs from the checked device tree")
    verify_art(entries, art)
    check_recovery_policy(entries["sepolicy"].payload)
    for name in ("system/bin/recovery", "system/bin/adbd"):
        entry = entries[name]
        if not stat.S_ISREG(entry.mode) or not entry.mode & 0o111:
            fail(f"recovery binary is not an executable regular file: {name}")
    if entries["system/etc/recovery.fstab"].payload != expected_fstab:
        fail("recovery fstab differs from the checked device tree")
    properties = entries["prop.default"].payload.splitlines()
    if b"persist.adb.tcp.port=5555" not in properties:
        fail("recovery properties omit the ADB TCP port")
    # Recovery loads only the ramdisk's prop.default, never the product
    # partition's properties. Without this one a kernel that lacks /dev/ashmem
    # (the mainline line) fails every ashmem_create_region caller in recovery.
    if b"sys.use_memfd=true" not in properties:
        fail("recovery properties omit sys.use_memfd, which the ashmem fallback needs")
    # The display is a Virtio-GPU dumb buffer, always B8G8R8X8 on the wire. Any
    # other minui format makes DRM declare a byte order nothing converts, and
    # the screen shows red and blue swapped.
    if b"ro.minui.pixel_format=BGRX_8888" not in properties:
        fail("recovery properties omit ro.minui.pixel_format=BGRX_8888, the dumb buffer's byte order")
    interface = entries["system/lib64/librecovery_ui_ext.so"].payload
    if b"eth1" in interface or any(
        token not in interface for token in (b"eth0\0", b"10.0.2.15\0", b"255.255.255.0\0")
    ):
        fail("recovery UI does not address the Virtio-net interface eth0")
    if "system/lib64/librecovery_ui_cuttlefish.so" in entries:
        fail("recovery retains the Cuttlefish interface policy")

    elf_count = 0
    needed_by: dict[str, set[str]] = {}
    available_libraries: set[str] = set()
    for name, entry in entries.items():
        if android_image.is_module_payload(PurePosixPath(name).name):
            fail(f"loadable-module payload remains in recovery: {name}")
        if stat.S_ISREG(entry.mode) and verify_elf(name, entry.payload):
            elf_count += 1
            needed_by[name] = elf_needed(name, entry.payload)
            path = PurePosixPath(name)
            if path.parent.name in ("lib", "lib64"):
                available_libraries.add(path.name)
    if elf_count == 0:
        fail("recovery ramdisk contains no target ELF payloads")
    for name, needed in needed_by.items():
        missing_libraries = sorted(needed - available_libraries)
        if missing_libraries:
            fail(
                f"recovery ELF dependency closure is incomplete for {name}: "
                f"{missing_libraries}"
            )
    return elf_count


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--android-root", type=Path, required=True)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--image", type=Path)
    source.add_argument("--disk", type=Path)
    parser.add_argument("--layout", type=Path)
    args = parser.parse_args()
    try:
        android_root = args.android_root.resolve()
        fstab_path = android_root / "overlay/config/recovery.fstab"
        expected_fstab = regular_file(fstab_path, "checked recovery fstab").read_bytes()
        expected_script = regular_file(
            android_root / "overlay/config/init.recovery.rc", "checked recovery script"
        ).read_bytes()
        check_recovery_script(expected_script)
        art = product_art(android_root)
        if args.image is not None:
            if args.layout is not None:
                fail("--layout is valid only with --disk")
            path = regular_file(args.image, "recovery image")
            offset, size = 0, path.stat().st_size
        else:
            if args.layout is None:
                fail("--disk requires --layout")
            path = regular_file(args.disk, "Android disk image")
            layout = regular_file(args.layout, "partition layout")
            offset, size = android_image.partition_range(
                layout, path, "recovery", VerificationError
            )
        with path.open("rb") as image:
            boot = android_image.parse_boot_image(image, offset, size, VerificationError)
            image.seek(boot.ramdisk_offset)
            compressed = android_image.read_exact(
                image, boot.ramdisk_size, "compressed recovery ramdisk", VerificationError
            )
        ramdisk = decompress_ramdisk(compressed)
        entries = android_image.parse_newc(
            android_image.RangeReader(
                io.BytesIO(ramdisk), 0, len(ramdisk), VerificationError
            ),
            lambda name, mode: True,
            VerificationError,
        )
        elf_count = verify_entries(entries, expected_fstab, expected_script, art)
    except (OSError, UnicodeError, struct.error, VerificationError) as error:
        raise SystemExit(f"LineageOS recovery: {error}") from error
    print(
        f"verified kernel-less LineageOS recovery: {len(entries)} entries, "
        f"{elf_count} aligned AArch64 ELFs"
    )


if __name__ == "__main__":
    main()
