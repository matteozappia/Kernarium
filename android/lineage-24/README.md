# LineageOS 24 UML guest producer

This directory owns the standalone LineageOS 24 guest producer for Darwin UML.
LineageOS 24.0 is Android 17: its tree is the AOSP `android-17.0.0_r1` release
with LineageOS's forks of the projects it changes. The exact source identity and
product name live in [`metadata/lineage.env`](metadata/lineage.env). The guest
kernel is not owned here: it is the mainline kernel line built with its Android
overlay, described in
[`../../kernel/mainline-6.18`](../../kernel/mainline-6.18/README.md#android-product).

The producer runs locally on an x86_64 Linux builder. Repository scripts accept
builder-local paths only; transport, machines, accounts, and credentials are
outside this repository.

## Producer boundary

`build/prepare-sources.sh` is the only producer command allowed to use the
network; it pins the Android source and the guest Mesa source. Patching, builds,
verification, image assembly, and publication are offline (a `build/make` topic,
route `p0002`, keeps `lunch` from calling LineageOS's network-reading
`roomservice.py`).

The producer has three independent outputs: the `lineage_andarium` target files
of the configured build variant (with the kernel-less `init_boot` and LineageOS
recovery images); one static GPT guest disk containing both boot ramdisks; and a
compact rootfs release installed by Apple consumers. Use the scripts under
`build/` in that order; each script's `--help` is the canonical interface.
`build/build-release.sh` runs the whole sequence on one builder, from source
synchronization to the signed release.

The kernel is an input, not an output: the `android-6.18` artifact the Mac
builds with `kernel/mainline-6.18/build/build-kernel.sh --product android` and
publishes with `publish-artifact.py --product android`. The build, the disk
assembly and the release publisher take it with `--kernel-artifact` and verify
it against the tracked mainline source. A release ships its kernel files
unchanged, and updating the artifact never republishes the GPT or invalidates a
guest bundle.

## Source and patch ownership

- `metadata/` pins the Android source: `base-manifest.xml` pins every Repo
  project and `lineage.env` records the snapshot and the product identity.
- `patches/projects.tsv` maps each changed project from its exact base to its
  final tree. The generated series under `patches/projects/` are the only
  maintained modifications to upstream projects; a route (`pNNNN`) is one
  project's series.
- `overlay/` owns the complete `device/kernarium/andarium` product tree and is
  synchronized as one verified unit.
- `third_party/mesa-venus/` and `third_party/meson2hermetic/` pin the guest
  Mesa source and the Soong-port converter, each with its own series.
- `tools/` holds the regenerators, verifiers and release tools; `support/`
  holds the tracked disk, release and instance policies.

Every series uses the shared [`scripts/patch_series.py`](../../scripts/patch_series.py)
format and is identified by the tree it produces: replay applies it to the
pinned base and requires the final tree recorded in `projects.tsv` or the owning
`metadata.env`. Never edit generated patch files; amend clean Git topic branches
and run the matching regenerator under `tools/`.

## Android product

The product is `lineage_andarium` (brand Andarium, manufacturer Kernarium,
device `andarium`; lunch target `lineage_andarium-cp2a-user`): the Cuttlefish
base with LineageOS's `common_full_tablet_wifionly` chain on top.
`overlay/lineage_andarium.mk` sets the LineageOS switches and names what the
product leaves out, chiefly the Cuttlefish virtual hardware that has no Darwin
UML implementation. `Build.SOC_MANUFACTURER` and `SOC_MODEL` are `Kernarium` and
`Virtual CPU`, which joined are the host's name for its virtual CPU.

- **ABIs.** A 64-bit system with a 32-bit application ABI: `arm64-v8a`,
  `armeabi-v7a` and `armeabi`, in that order (`zygote64_32`). Daemons, HALs,
  recovery and the ramdisks stay 64-bit, and WebView renderers too (route
  `p0007`). The kernel runs 4 KiB pages only, because Android's 32-bit libraries
  are 4 KiB aligned. ABI support does not lower the minimum installable target
  SDK; test an older APK with `adb install --bypass-low-target-sdk-block`.
- **Applications.** Settings, Trebuchet, Files, Package Installer, the LineageOS
  WebView, LatinIME, ThemePicker and a curated set (gallery, music, calendar,
  calculator, PDF viewer, backup). There is no browser, app store, install
  restriction, Google or microG. Applications that need absent hardware or
  LineageOS cloud services are excluded by name in the product makefile, and the
  build and the verifier assert that list.
- **Settings.** Settings is the stock application apart from route `p0009`,
  which removes the pages for hardware the product lacks (the Connected devices
  entry, the Bluetooth developer option, the media output switcher, and the
  hearing, Bluetooth pairing, telephony, biometric and USB pages) and hides the
  Wi-Fi hotspot, wireless display and System update pages.
- **Hardware not advertised.** Telephony, GNSS, NFC, UWB, Thread, camera,
  biometric, vibrator, secure element, USB, Bluetooth and Trusty. SecureElement
  is kept but not persistent (route `p0024`): nothing starts it at boot, and the
  first `SEService` client that binds it starts it.
- **Diagnostics.** A `user` image needs no guest root for diagnostics: the
  host-captured console, UML's mconsole and tracefs at `/sys/kernel/tracing`
  cover them. Only what these cannot reach needs a `userdebug` build with `su`.

### Build variants

`LINEAGE24_BUILD_VARIANT` in `metadata/lineage.env` is `user` or `userdebug`;
lunch, the target-files verifier, the release manifest and the accepted-release
descriptor all follow it. `user` is the default and the only variant that is
signed, published or accepted. It keeps the stock shell privilege boundary: no
`su`, no `adb root`, `ro.debuggable=0`, no permissive SELinux domain, and the
verifier rejects debug-only payload, debuggable applications and the in-tree
test applications. `userdebug` carries `su`, is debuggable, keeps the AOSP test
keys and is never re-signed. Each variant builds in its own output directory and
`build-aosp.sh` refuses the other one ([Release signing](#release-signing)).

### First boot and provisioning

LineageOS Setup Wizard handles the first boot of a fresh guest; completing it
provisions the guest (both settings 1, the wizard's HOME activity disabled), so
later boots go straight to the launcher. The image has no trade-in mode: its
only boot-time requester, DeviceDiagnostics, is excluded, so adbd stays one
process through a first boot.

A harness that erases a guest provisions it over adb with
[`tools/android_provision.py`](../../tools/android_provision.py): it sets both
settings, waits until the wizard is bound, then disables the wizard package for
user 0 and stops it, and changes nothing in the image. It returns only after the
wizard has no process and no status bar record and adbd has been stable with no
trade-in mode pending. A measurement of the first-boot experience itself keeps
the wizard.

The wizard shows Welcome, Language, Date and time and Theme (a secondary user
sees Welcome and Theme). Finish on the Theme page ends the wizard and goes
straight to the home screen: LineageOS's closing page, with its logo and home
button, is not shown (route `p0026`); the verifier requires the two flow scripts
in the wizard's resource overlay byte for byte. The other
LineageOS pages are left out because a default answers them or they cannot apply
to a virtual device: Network (the virtual Wi-Fi is already connected), Location
(stays on), Screen lock (a fresh guest has none), Navigation (three buttons, the
platform default; route `p0026` removes the wizard's forcing), Restore and
Andarium features (not useful here), and Bluetooth, SIM, device-specific setup,
biometrics and recovery update (no such hardware or script).

The home screen is one empty page with a dock of Files and Settings: no
widget, no second page and no other item. Calendar, Gallery, Music and
Calculator stay installed and are in the app drawer. The Launcher3 resource
overlay owns the layouts and the verifier requires them. The launcher reads its
layout once, so a guest created earlier keeps its home screen.

### Motion sensors

The product installs Android's AIDL multi-HAL service and a motion sub-HAL
(`overlay/sensors/`) advertising an accelerometer and a gyroscope with
continuous delivery and 10 ms minimum periods. Andarium supplies samples only
while its Gyroscope switch is on and an application uses the sensor. The sub-HAL
accepts a single stream on vsock port 5556 from host CID 2 (no guest-originated
source) and tells the host which sensors are active.
`overlay/sensors/motion_protocol.hpp` and
`Andarium/AndariumCore/Sources/AndariumCore/MotionStream.swift` own the wire
format. Axes match the mounted virtual display, Core Motion acceleration is
multiplied by -9.80665, and events carry the guest's `CLOCK_BOOTTIME` at receipt:
a live input path, not a synchronized recording. Andarium's
[scene policy](../../Andarium/README.md#devices) describes windowed operation.

### Networking

The guest's one network device, `eth0`, is the host's user-mode network (SLiRP,
10.0.2.0/24) and the management NIC: adb is reached through the host's forward
to 10.0.2.15, so the framework never manages `eth0`. `kernarium_net_setup`
(`overlay/tools`) prepares it at `post-fs-data` and stacks the `virt_wifi`
device `wlan0` on it, and the kernel needs `CONFIG_MACVLAN`, `CONFIG_CFG80211`
and `CONFIG_VIRT_WIFI` built in (the verifier requires them). Apps see Wi-Fi
only, the open SSID `VirtWifi`, because the product declares
`android.hardware.wifi` and not `android.hardware.ethernet`; turning Wi-Fi or
airplane mode off takes apps offline while adb keeps working. There is no
SoftAP, Wi-Fi Direct, Aware or RTT, and `wificond` is not shipped.

### Audio, settings and lock screen defaults

The vendor audio policy exposes one built-in microphone, the Virtio sound
capture stream. The product declares `android.hardware.microphone` permanently,
and the host decides whether the stream carries silence (the default) or its
microphone. It also declares `android.software.midi`, which starts MidiService
for applications' virtual MIDI devices; there is no USB or Bluetooth MIDI
transport. The primary output has a 5 ms HAL buffer, so AudioFlinger gives it a
fast mixer, and its writer runs at `SCHED_FIFO` priority 3 and writes straight
into an ALSA ring of four such periods (route `p0005` and the
`ro.hardware.audio.tinyalsa.*` vendor properties); the boot command line lowers
the Virtio sound driver's minimum period to 5 ms for it. A low-latency AAudio
stream with a data callback that leaves its capacity unspecified starts with a
two-burst buffer and grows it by one burst per underrun until the app sets a
size (route `p0028`). A Virtio battery device reports the Apple host's
percentage and charging state.
The swipe lock screen can be turned on: `ro.lockscreen.disable.default` turns it
off for user 0 of a fresh `/data` only.

### Debugging and adb

Fresh settings databases keep Developer options and USB debugging off, and
`ro.adb.secure` keeps the build type's value (route `p0001`). adbd listens on
TCP port 5555 and vsock port 5555 and retains the stock authorization prompt.
Three immutable launch properties, which adbd reads itself (route `p0011`),
carry host-owned choices that bundle command lines may not override:

- `ro.boot.kernarium.adb_auth` can disable the authorization check for host-side
  diagnostics: iOS fixes it to one (only the automation runtime lets a test
  launch turn it off, on a loopback forward,
  [`../../Kernarium/README.md`](../../Kernarium/README.md#automation-runs)), the
  standalone macOS product fixes it to zero.
- `ro.boot.kernarium.adb_tcp` is 0 when the launch has no host forward, as in
  the iOS release: adbd then listens on `vsock:5555` alone.
- `ro.boot.kernarium.adb_key` is the adb public key the host application
  authorizes for the boot; adbd accepts it whatever the user's setting.

The user's debugging setting stays meaningful while adbd remains the host's
channel: route `p0007` records the setting in `persist.sys.usb.config` and
restarts adbd instead of stopping it, and route `p0011` refuses every key but the
host's, with no prompt, while USB and wireless debugging are both off. `adb root`
is refused at once on a `user` build whatever the authorization policy, with
AOSP's answer for a production build (route `p0011`). SELinux stays enforcing in
both variants. `tests/integration/android/run_android_adb_debugging.py`
qualifies this contract.

### Framework and CTS behaviour

Framework, policy and CTS fixes are patch topics under `patches/projects/`
(each topic's commit message states its reason) or overlay files that the
verifier requires; the vendor SELinux additions live in `overlay/sepolicy/`. The
product uses software KeyMint and gatekeeper, enforcing SELinux policy, no
`system_other` image and no loadable modules or DLKM partitions. These CTS
outcomes are known and not defects of the image:

- LineageOS's restricted networking default is kept; a CTS run sets
  `restricted_networking_mode` to 0 when the guest starts.
- Tests that reboot the device cannot pass where reboots are disabled, as they
  must be when the emulator exits on reboot.
- `JobSchedulingTest#testAnr_*` and `SurfaceSyncGroupTests#testProcessCrash`
  assume a smaller `hw_timeout_multiplier` than a multiplier of 5.
- dEQP's `deqp:testercore` can abort at exit on a destroyed mutex (an upstream
  exit race with no effect on any result), and the EGL `get_frame_timestamps`
  cases need a quiet host.
- HEVC 4K decoding at 60 frames per second and 32-bit encoding at the largest
  sizes miss the published point
  ([hardware video](#hardware-video-encoding-and-decoding)).
- DocumentsUI (Files) on a smallest width of 720 dp or more can throw an
  `IllegalStateException` from AppCompat's `CascadingMenuPopup` while its
  overflow menu changes during the popup's exit transition; real tablets share
  this upstream defect, and there is no product fix.

### Boot, memory and time

- A first boot compiles nothing: `tools/precompile-first-boot-apps.py` compiles
  the packages Soong leaves without artifacts, and `build-aosp.sh` verifies the
  packaged tree.
- The boot animation is off, and boot runs with expedited RCU grace periods that
  the vendor init script turns off at `sys.boot_completed`. The Mac launcher and
  Kernarium read the release's one command line file.
- The launcher sets `androidboot.hw_timeout_multiplier`, which scales the
  framework's ANR, watchdog and input timeouts, from the guest's vCPU count: 3 at
  six or more, 5 below, where the gadget engines are slower than a phone
  (`darwin/device/block/android_boot.hpp`). The release's command line does not
  set it, and the vendor init script falls back to 5 when a launch passes none.
  The launchers refuse any value of it in a release's command line except the
  `=5` that earlier releases carry, which they drop.
- The guest has a compressed swap of half its RAM (one zram entry in
  `fstab.uml`), enabled at `sys.boot_completed`. PinnerService does not lock the
  home app's files, and `kernarium_reclaim_boot_apps.sh` kills only the cached
  processes of a reviewed list of boot-started apps after boot completes.
- lmkd ends the cached app that holds the most host graphics memory while the
  kernel reports host GPU pressure in `/sys/class/drm/card0/gpu_memory_report`
  (route `p0027`; `ro.lmk.gpu_reclaim`, set by the product, turns it on). It does
  nothing on a kernel without the file.
- The virtio-gpu display is paced by a kernel vblank timer, so the product drops
  the inherited `present_fence_not_reliable` property and the guest needs a
  kernel with the pacing. Incremental installs need a kernel with Incremental FS.
- The guest's wall clock is the host's, so the platform takes no network time;
  the verifier fails any NTP server or network time origin in the framework
  overlay.

### Time zone

A new guest starts on GMT and the platform has no automatic time zone, so the
host application passes the zone it is in at every start
(`androidboot.kernarium.timezone`, an IANA name the runtime has checked; the
standalone macOS launcher passes none). `kernarium_time_zone.sh` applies it with
`cmd alarm set-timezone` at boot completion, but only while nobody in the guest
has chosen a zone: it replaces a zone only if that is the one it applied last
(marker `persist.sys.kernarium.timezone_applied`), so a zone picked in Android
stays.

### Branding and diagnostics

The Setup Wizard names the system Andarium through its runtime resource
overlay; Settings, About, the boot animation, the fingerprint and the build
properties keep LineageOS's names. LineageOS's statistics reporting is removed
rather than disabled (route `p0025` removes LineageParts' statistics feature,
route `p0026` the wizard's diagnostic data row), and the verifier fails an image
that still carries the uploader.

## Graphics

Both graphics APIs come from one Mesa build of this project's own guest Mesa
source rather than from the AOSP Mesa snapshot, so the Android guest and the
Linux guest run the same drivers against the same renderer. GLES is Mesa's Virgl
gallium driver behind `libEGL_kernarium`, `libGLESv1_CM_kernarium` and
`libGLESv2_kernarium` (`ro.hardware.egl=kernarium`); the Vulkan HAL is Mesa's
Venus driver over Virtio-GPU (`ro.hardware.vulkan=virtio`); gralloc is the
allocator's own `gralloc.minigbm` (`ro.hardware.gralloc=minigbm`); and
presentation is `VK_ANDROID_native_buffer`. The host side of this stack is in
[`../../docs/graphics.md`](../../docs/graphics.md#android-guest-requirements).

The Android guest allocates Venus memory synchronously: vendor init sets
`debug.mesa.vn.perf=no_async_mem_alloc` at early-init, before any process that
loads the driver starts, so a host GPU budget refusal reaches the application
as `VK_ERROR_OUT_OF_DEVICE_MEMORY` instead of aborting it. The verifier requires
the setting and that applications, SurfaceFlinger and the shell may read it.

The boot command line is the only writer of the three graphics HAL selections,
the OpenGL ES version and `androidboot.lcd_density`; every launcher passes the
density and a release's command line may not set it. The verifier refuses a
vendor `ro.hardware.egl`, `ro.hardware.vulkan` or `ro.hardware.gralloc`. The
display follows the host view
([`../../docs/graphics.md`](../../docs/graphics.md#dynamic-native-geometry)),
density stays at its launch value, and the touchscreen's absolute range is fixed
at 0 through 32767 so touch stays exact at every size. The iOS host's
touchscreen supports ten contacts; VNC remains a single pointer.

`third_party/mesa-venus/` pins the source as three independent inputs: the
upstream Mesa revision, the guest Vulkan series under
[`../../tools/rootfs/vulkan/`](../../tools/rootfs/vulkan/README.md), and the
Android port series (the generated Soong port and the few source changes only
Android needs). A guest replay assigns new commit identities each time, so the
guest half is pinned by tree. The HAL and the host renderer must speak the same
Venus protocol revision: a change to the protocol series or the Vulkan-Headers
pin needs a regenerated codec (`tools/generate-mesa-venus-port.py protocol`), a
port replay and a new release, and `tools/verify-mesa-venus-source.py` refuses a
pin that differs from its owner. The Android hardware buffer handle type that a
swapchain needs arrives with the guest Vulkan epoch pinned in
`third_party/mesa-venus/metadata.env`.

The product declares OpenGL ES 3.2 (`androidboot.opengles.version=196610`),
`android.hardware.opengles.aep` and `android.software.opengles.deqp.level`
132776705, the level at which every EGL, GLES2, GLES3 and GLES31 dEQP list of
the Android 17 CTS passed whole on both ABIs. A declared level makes the CTS run
every list dated up to it, so the verifier pins the level and requires the
extension pack, and a platform update that moves the `latest` level file fails
verification until its new lists pass.

The product declares Vulkan 1.4 (`level` 1, `compute` 0) and deliberately no
`android.software.vulkan.deqp.level`: the driver has not been qualified against
Android's Vulkan dEQP must-pass list, and the verifier refuses a declaration
until those lists pass. One gap is known: `vkMapMemory` of host-visible memory
exported as a hardware buffer fails with `VK_ERROR_MEMORY_MAP_FAILED`, because
gralloc backs such a buffer with a classic 3D resource that Venus refuses to map
by design. `overlay/tools` ships pass-or-fail checks of the presentation and
buffer paths (`kernarium_vk_present`, `kernarium_vk_ahb_import` and the
`kernarium_ahb_*` and `kernarium_egl_configs` programs).

## Hardware video encoding and decoding

The host's VideoToolbox encoders and decoders reach the guest as V4L2 stateful
devices (Virtio video, [`darwin/device/video`](../../darwin/device/video/README.md))
and the product exposes them through Codec2. The vendor service
`android.hardware.media.c2-service-v4l2` of `external/v4l2_codec2` (route
`p0018`, which also adds the HEVC component) serves AVC and HEVC encoders and
decoders beside the software `c2.android.*` components; MediaCodec chooses the
hardware decoders first. Encoder parameters come from the device, and a
capability the device does not list is not advertised. HDR content is shown as
SDR because the host has no P010 sampler.

`overlay/config/media_codecs_c2.xml` is the product's one vendor codec list. Its
performance points, the encoder floors, the instance limits and pixel rates, and
the service's SELinux and seccomp additions are required by the target-files
verifier, which also refuses a hardware decoder beyond the two. Qualification is
opt-in
([`../../docs/testing.md`](../../docs/testing.md#android)).

## Payload reduction

Payload reduction is done through product configuration and regenerated AOSP
patches, never by deleting files from a completed image.
`KERNARIUM_REMOVED_PACKAGES` in `overlay/lineage_andarium.mk` lists what the
product omits: HAL APEXes with no Darwin UML hardware, AVF guest payloads, OTA
and DSU executables, and Cuttlefish host-monitoring services. The build and the
verifier reject any excluded module that reappears. The thermal and CAS HAL
APEXes (CTS needs both) stay, as do DeviceLock, Virtualization and the modular
framework containers, which the platform SDK classes link. EasterEgg stays
too: Settings' Android version row opens the platform logo screen, which starts
the egg, and the verifier requires its package.

Android suspends itself when the screen is off and nothing holds a wakelock, and
this machine's adb host arrives over the network, which only briefly wakes a
suspend ([kernel](../../kernel/common/README.md#suspend-wake-and-the-management-console)).
adbd's `p0011` topic therefore sets `sys.kernarium.adb.host_connected` while it
has an adb host, and product init holds Cuttlefish's `suspend_blocker` wakelock
for it. The wakelock holds back only Android's own autosuspend: a suspend the
host requests through the management console still suspends the guest.

## Static disk and boot contract

The guest sees exactly two disks; a third would stall boot, because first-stage
init mounts a partition by name from any Android GPT disk it finds.

- The **system disk**, `guest/system.img`, is read-only and ships with the
  release. One GPT holds `init_boot`, `recovery`, and the five EROFS partitions
  (`system`, `system_ext`, `product`, `vendor`, `odm`), each exactly its image
  rounded up to 4 KiB and packed back to back. The disk is raw and attached as
  `ubd0r`.
- The **data disk** is the guest instance's writable disk, a sparse GPT the host
  creates (see [`darwin/device/block`](../../darwin/device/block/README.md)):
  `misc`, `metadata`, a reserved gap, and `userdata` to the last MiB. The host
  writes no filesystem: first-stage init formats metadata and userdata on first
  boot. It is attached as `ubd1`, with discard.

`support/image/disk-policy.json` is the tracked policy: partition names, GUIDs,
packing rules, and the data disk template with its capacity range (4 through
128 GiB, 8 by default). `tools/ubd-disk.py assemble` turns it and the built
images into `system.img` and the release's `partition-layout.json` (schema 2).
The host reads only that file, never the policy, so a layout is a release
property: changing a size or an offset needs no host change. The host does not
hash at boot; the installer verifies a release once.

The data disk only grows: the host raises its size and rewrites its GPT, and
Android grows the mounted `userdata` filesystem online at every boot. Recovery
does not grow userdata, and neither guest rewrites a live partition table. There
is no `super`, dynamic partition, Virtual A/B, AVB, OTA slot, or DLKM partition.

The five read-only partitions are compressed EROFS (Zstandard level 15, 16 KiB
physical clusters on 4 KiB blocks), and so is every APEX payload except the
presigned CTS shim APEX. The parameters are written once as
`UML_ANDROID_EROFS_COMPRESSOR` and `UML_ANDROID_EROFS_PCLUSTER_SIZE` in
`overlay/lineage_andarium.mk`, and routes `p0023` and `p0013` give AOSP's EROFS
tools Zstandard support. `userdata` is an ordinary unencrypted ext4 filesystem:
the emulator exposes no hardware-backed KeyMint and the host application sandbox
protects the bundle.

`init_boot` and `recovery` are kernel-less boot-image-v4 ramdisks from the signed
AOSP target files; `recovery` is the stock LineageOS recovery adapted to the
virtual hardware (`overlay/recovery/`, route `p0016`). The kernel stays outside
the disk in the selected runtime artifact. Boot mode `auto` follows the standard
command in the writable `misc` partition and is the launcher default.

A guest reboot restarts the guest in the same host process, so `adb reboot`,
`adb reboot recovery` and `adb reboot bootloader` all return to a running guest.
Every restart reads `misc` again: `boot-recovery` boots recovery, which clears
it, and no command boots Android. There is no bootloader, so the launcher
behaves as a bootloader that continues and clears a `bootonce-bootloader`
command. A guest that restarts within 15 s of booting five times in a row ends
the launch with exit status 3.

`build/assemble-image.sh` owns ramdisk composition, system disk assembly and
verification, and `tools/verify-lineage-recovery.py` checks the recovery image.

### Add-on packages

Recovery installs a flashable ZIP (an application suite, for example) that is
sideloaded to it; its minadbd listens on vsock port 5555, which is how
[Andarium](../../Andarium/README.md#android-operations) sends one. A package
signed by a key recovery does not trust is installed only after the person
confirms it on the recovery screen, on every build variant (route `p0016`).

The read-only partitions stay as the release made them. An installer that
mounts `system`, `system_ext` or `product` read-write gets that partition's
add-on layer instead: a sparse ext4 image under `/data/vendor/kernarium_addons`
that `overlay/tools/kernarium_addons.sh` offers through `/dev/block/by-name`
while a sideload runs. At `late-fs` Android mounts each layer that holds a
payload read-only over its partition (`overlay/config/init.vendor.rc`), so
the layers follow the guest's data: they survive a system update and go with
a factory reset or an erased guest. An installer that needs to read the
existing system partition, or to change `vendor`, `odm` or a boot ramdisk, is
not supported.

## Release installation

`support/release/release-manifest.schema.json` defines the compact rootfs
release. It binds the system disk and its layout, boot ranges, command line,
target-file support, and source provenance. The Android section records the
security patch level and the build number (`ro.build.version.incremental`),
which a release must set numerically (`build-aosp.sh --build-number N`): it is
both the user-visible release number and the monotonic key by which the host
refuses a downgrade. The checked `metadata/accepted-release.env` selects one
reviewed release without recording a builder path.

The manifest also records, as `outer.input_trees`, the Git object ID of every
path that [`support/release/input-paths.tsv`](support/release/input-paths.tsv)
marks `input`: the overlay, product configuration, patch series, route table,
support files, base manifest and the producing tools, each with its reason in
the list. An object ID follows content, so it survives a history rewrite and a
builder that works from an exported snapshot; the publisher takes it from the
clean checkout it runs in. The accepted descriptor repeats the IDs
(`LINEAGE24_ACCEPTED_INPUT_TREES`), and `install-release.py --print-acceptance`
prints the whole descriptor for a candidate. The AppStore configuration of
Andarium compares them with the commit it archives
([`scripts/check-embedded-artifacts.py`](../../scripts/check-embedded-artifacts.py)).
Verifier-only tools, documentation and tests are excluded, and a tracked file
under this directory that the list does not classify fails
`lineage24-release-inputs`. A release of schema 6 predates the IDs and records
none, so the check refuses it as unverifiable.

After copying a reviewed candidate to the workstation, install it with:

```sh
android/lineage-24/tools/install-release.py \
  --source /absolute/local/path/to/release
```

The installer validates the candidate, including every system disk partition
hash, and installs it atomically below `.build/android/releases`. It never
replaces an existing release. Apple CMake does not import the rootfs release
and does not invoke Repo, Soong, Kbuild, image assembly, publication, or
transport.

The release manifest keeps the kernel build that qualified its target files as
historical provenance only. Apple runtime selection uses an independent
compatible Android kernel artifact and compares no rootfs, kernel commit or
emulator release at launch, so a kernel-only update advances only
[`accepted-android-4k.env`](../../kernel/mainline-6.18/artifacts/accepted-android-4k.env)
and keeps the accepted release.

### Release signing

Every `user` build is signed with one private key set that never enters the
repository, a log or a release; there is no unsigned publication and no key
generated per build. `tools/publish-release.py --signing-keys DIR` takes the
unsigned target files and `DIR`, a directory owner-only (no group or other
access) that the caller deletes; the tool copies no key and refuses to sign any
other variant. It signs in a private work directory with the AOSP
`sign_target_files_apks`, assembles the system disk from the signed archive, and
deletes the work directory whether or not signing succeeded. `--disk-dir`,
`--mkbootfs`, `--mkbootimg` and `--first-boot-artifacts` are required.

The signed archives name the release certificate `keys/releasekey.x509.pem`
(`verify-target-files.py --signed` checks it), so no build-host path or temporary
name enters a release. Signing fails when any file stays signed with a key
outside `DIR`, and the tool requires the system's and the recovery's
`otacerts.zip` to trust the release certificate and no public AOSP or LineageOS
certificate. A presigned file keeps its upstream signature and is named in the
build receipt. The key directory, its backup and the transfer to the builder are
the maintainer's responsibility.

### Superseded releases

After a replacement release is validated, remove the superseded Android build,
release, transfer, and guest-bundle artifacts from the local `.build` tree,
local temporary directories, and the Android build machine. Resolve releases
and bundles from their manifests and build outputs from their recorded
invocation and canonical output root, and delete only explicit Android paths.
Preserve the current accepted release and its active writable bundle, the
Android source and patch-producer checkouts, accepted kernel inputs, dependency
prefixes, non-Android guests, and unrelated files beside a bundle.

## Storage accounting

The framework reports exact filesystem bytes for the static virtual disks:
`StorageManager` sums `/data` and the five mounted OS filesystems, and Settings
derives its used space and System category from those counts. Retail capacity
rounding does not apply to these virtual disks. The `frameworks/base` storage
topic in route `p0007` owns this policy.

## Guest instance storage

A guest instance is the writable half of a guest: a directory holding the data
disk, `data.img` (the creation and growth rules are in
[`darwin/device/block`](../../darwin/device/block/README.md)), and
`instance.json`, which records the release the disk was last started with. The
system disk is not part of an instance. Every launcher that keeps instances,
the macOS script and the Andarium app, applies the same rules before each
start; [`tools/android_instance.py`](../../tools/android_instance.py) is the
reference implementation and
[`support/instance/update-decisions.json`](support/instance/update-decisions.json)
holds decision vectors and the record's transitions that any other
implementation must reproduce. The release's identity comes from its manifest
and layout, never from hashing the disk at launch.

The build number orders releases; the rules compare nothing else. Before a
start:

| Case | Action |
| --- | --- |
| no instance | create it; the host creates the data disk, which the guest formats on first boot |
| same release | start |
| newer build, same `data_layout` | snapshot, record the pending update, start; Android upgrades its own data |
| newer build, newer `data_layout` | snapshot, run the registered migration (none exists yet), start |
| older build | refuse: Android's key store, package manager and apexd do not go back |
| same build, another release or system disk, or a `data.img` without `instance.json` | refuse |
| an unfinished update, same build | retry with its snapshot kept, restore, or reset |
| an unfinished update, newer build | restore the pre-update snapshot, then update directly to the newer build |

An update is finished when the host first sees the guest reach
`sys.boot_completed`: the pending update is cleared and the snapshot deleted. A
newer release after that updates from the data as it is, with a snapshot of its
own. Any older build can update directly to any newer build.

The snapshot, `data.img.pre-<release_id>`, is an APFS clone (a volume without
clones refuses the update) that lives only while the update is unfinished; a
restore puts back the data the new release started from and does not boot the
previous release. An update whose first start fails offers three ways out: start
it again keeping the snapshot, restore the snapshot and update afresh, or reset
the instance (delete it and create it anew), which is also the way out of a
refused downgrade. A future data layout changes the partition table only inside
the reserved gap, never moving `userdata`. The app decides whether to exclude the
instance directory from backup.

## Apple consumers and guest bundles

The macOS Android product is configured with the `macos-android17` preset. Its
build requires a compatible Android kernel artifact; launch takes any rootfs
directory with the expected payload layout and one directly writable GPT image.
It does not alter the normal Linux executable or search for `rootfs.erofs`.

[`../../tools/boot_android.py`](../../tools/boot_android.py) is the ordinary
macOS launcher. It selects the accepted installed release and a guest instance
(see [Guest instance storage](#guest-instance-storage)), applies the update
rules, and starts the emulator on the release's system disk and the instance's
data disk. A disk never shrinks. The launcher exposes guest ADB only on host
loopback; `tools/boot_android.py --help` lists the session options, and the
guest records silence unless `--audio-input host` records from the Mac's
microphone (see the [audio device README](../../darwin/device/audio/README.md#microphone)).

Kernarium represents one Android guest as a `.kern` directory containing:

- `release-manifest.json`;
- `boot/kernel-command-line.txt`;
- `guest/system.img`, the release's read-only system disk, and
  `guest/partition-layout.json`, which describes it; and
- `guest/data.img`, the guest's writable data disk, which the runtime creates at
  the first launch and only grows afterwards.

The kernel is supplied by the runtime framework and is not bundle payload. The
manifest is provenance rather than a runtime compatibility token. Android
appends the host-owned display density, hardware timeout multiplier, ADB
authorization policy, ADB host key, ADB TCP policy, and tagged-pointer option at
launch, and launches write
persistent guest changes only to `guest/data.img`. How Kernarium keeps,
relaunches, and copies a bundle is in
[`../../Kernarium/README.md`](../../Kernarium/README.md#guest-storage).

Andarium carries the accepted release instead:
`Andarium/scripts/stage-system-image.py` checks it against its own manifest and
stages the system disk, the partition layout, the kernel command line and the
manifest, at their release paths, for the application to bundle. See
[`../../Andarium/README.md`](../../Andarium/README.md#build).

## Validation boundary

Producer verification covers pinned source/patch identity, target files, VINTF,
SELinux policy, executable alignment, module exclusion, partition layout, boot
ramdisks, and release inventory. Runtime boot, persistence, recovery, graphics,
input, networking, connected-device memory limits, and application compatibility
are separate Apple-product gates.

Historical boot, ART, memory, and topology experiments are summarized in
[`../../docs/optimization-history.md`](../../docs/optimization-history.md).
