Kernarium
===

> This repository is a fork of [imxieyi/Kernarium](https://github.com/imxieyi/Kernarium).
> It follows upstream and adds features of its own to Andarium, starting with
> flashing add-on packages (ZIP) through recovery.

Run a real Linux kernel natively on iOS, through the magic of [User-mode Linux](https://en.wikipedia.org/wiki/User-mode_Linux).

## Apps

### Andarium

An Android emulator app built on the Kernarium runtime is available in [TestFlight beta](https://testflight.apple.com/join/qyPvJTUE). Source code is available under [`Andarium/`](/Andarium/).

### Kernarium

A generic Linux emulator app capable of running various Linux distributions. It's still at an early stage of development and isn't ready for release yet. Source code is available under [`Kernarium/`](/Kernarium/).

## Overview

The User-mode Linux kernel is compiled to native arm64 code, then linked to an iOS runtime framework. The kernel runs natively without emulation. Userspace programs are emulated using an [iSH](https://github.com/ish-app/ish)-style threaded interpreter, with SMP support. Guest GPU acceleration is provided by [KosmicKrisp](https://docs.mesa3d.org/drivers/kosmickrisp.html), a translation layer from Vulkan to Metal.

This emulator architecture sits between a full system emulator (like [UTM](https://github.com/utmapp/UTM)) and a full userspace emulator (like [iSH](https://github.com/ish-app/ish)). It combines the benefits of a real Linux kernel and a userspace emulator that only needs to emulate userspace code. It's capable of running advanced workloads including Docker containers, Linux desktops, Wine/Proton and a full Android system at decent speed on modern iOS devices.

## Features

- Kernel
    - Mainline 6.18 LTS kernel for both Linux and Android guests
    - Supports most kernel features, including namespaces, SELinux and more
- CPU emulation
    - Supports `arm64`, `arm32`, `x86_64` guest instructions
    - Both interpreter and JIT execution modes (interpreter-only for TestFlight release)
- GPU acceleration
    - Vulkan 1.4 via [KosmicKrisp](https://docs.mesa3d.org/drivers/kosmickrisp.html)
    - OpenGL 4.6 & GLES 3.2 via [Zink](https://docs.mesa3d.org/drivers/zink.html)
    - Hardware video encoding and decoding (H.264, HEVC) via [VideoToolbox](https://developer.apple.com/documentation/videotoolbox)
- Storage
    - Supports virtual disks via UBD driver, with discard support
    - Supports any Linux filesystem including ext2/3/4, erofs, xfs, ...
    - Supports loop devices and FUSE
- Network
    - Full Linux networking stack
    - Guest network access via [libslirp](https://gitlab.freedesktop.org/slirp/libslirp)

## Build or Embed

Point your coding agent at this repo if you want to build the project or embed its runtime in other apps. The agent guide is [`AGENTS.md`](/AGENTS.md), and the documentation is under [`docs/`](/docs/).

## License

This project is licensed under GPL-2.0-or-later, except where a file's SPDX header says otherwise; see [`LICENSES/`](/LICENSES/).
