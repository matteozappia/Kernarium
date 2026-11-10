# SPDX-License-Identifier: Apache-2.0
#
# Copyright 2026 The Android Open Source Project
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

# Select the UML-safe branches in the inherited Cuttlefish product before it
# is evaluated. The Darwin machine has no nested Trusty VM, modem, NFC,
# Bluetooth, GNSS, biometric, secure-element, or camera transport, and its
# Wi-Fi is the kernel's virtual one (kernarium_net_setup).
TRUSTY_SYSTEM_VM := disabled
UML_ANDROID_SECURITY_HALS := nonsecure
UML_ANDROID_BUILTIN_KERNEL := true
UML_ANDROID_STATIC_STORAGE := true
UML_ANDROID_DISABLE_PROJECT_QUOTAS := true
UML_ANDROID_DISABLE_AVF := true
UML_ANDROID_DISABLE_IDENTITY := true
UML_ANDROID_DISABLE_REBOOT_ESCROW := true
UML_ANDROID_DISABLE_LEGACY_VNDK := true
UML_ANDROID_MULTILIB := true
# A user build of the inherited Cuttlefish product adds ro.adb.secure=0 to the product
# partition; this keeps the build type's value (see the adb paragraph below).
UML_ANDROID_KEEP_ADB_SECURE := true
# The compressed EROFS of the five read-only partitions and of every APEX
# payload: the compressor with its level, and the physical cluster size in
# bytes. These two lines are the only place either value is written;
# BoardConfig.mk and the APEX payload settings below hand them to the image
# builder and apexer, and the target-files verifier reads them from here.
UML_ANDROID_EROFS_COMPRESSOR := zstd,15
UML_ANDROID_EROFS_PCLUSTER_SIZE := 16384
BOARD_HAVE_BLUETOOTH := false
CF_VENDOR_NO_UWB := true
CF_VENDOR_NO_THREADNETWORK := true
LOCAL_ENABLE_LIGHT := false
LOCAL_ENABLE_OEMLOCK := false
LOCAL_ENABLE_NEURALNETWORKS := false
# Android's multi-HAL service loads only the private host motion backend.
LOCAL_ENABLE_SENSORS := true
LOCAL_SENSOR_FILE_OVERRIDES := true
LOCAL_SENSOR_PRODUCT_PACKAGE := \
    android.hardware.sensors-service.multihal \
    android.hardware.sensors@2.1-impl.andarium
LOCAL_ENABLE_NFC := false
LOCAL_ENABLE_FRP := false
LOCAL_GNSS_PRODUCT_PACKAGE :=
# Select the inherited HIDL primary HAL explicitly so Cuttlefish does not also
# append its MMAP-capable product-property defaults.
LOCAL_AUDIO_PRODUCT_PACKAGE := \
    android.hardware.audio.parameter_parser.example_service \
    com.android.hardware.audio
LOCAL_USE_VENDOR_AUDIO_CONFIGURATION := true
# The Vulkan driver of this product is Mesa's Venus HAL below, not the
# Cuttlefish com.google.cf.vulkan APEX. That APEX carries the gfxstream and
# SwiftShader drivers, their feature declarations, and an init script that
# sets ro.vulkan.apex; the platform Vulkan loader then resolves
# vulkan.<ro.hardware.vulkan>.so only inside that APEX linker namespace and
# never reaches /vendor/lib64/hw. Dropping it also drops SwiftShader's
# insecure executable-memory requirement.
TARGET_VULKAN_SUPPORT := false
TARGET_DISABLE_BIOMETRICS_FACE := true
TARGET_NO_TELEPHONY := true
TARGET_USES_CF_RILD := false
TARGET_DEDICATED_RECOVERY := true
TARGET_NO_RECOVERY := false

# LineageOS switches, read while its configuration is inherited below. The
# machine has no camera, no charger or fastboot transport, and no hardware to
# apply effects to, so the matching defaults of the LineageOS product chain stay
# out. Its microphone is the Virtio sound capture stream (config/
# primary_audio_policy_configuration.xml, config/kernarium_core_hardware.xml). Debug builds carry `su` for the
# development tooling; a user build never does.
PRODUCT_NO_CAMERA := true
TARGET_EXCLUDES_AUDIOFX := true
# The Android UML ELF is built and published independently; the board stages it
# from the kernel artifact, so LineageOS's own kernel build stays off.
TARGET_NO_KERNEL_OVERRIDE := true
TARGET_DISABLE_FASTBOOTD := true
WITH_LINEAGE_CHARGER := false
ifneq ($(TARGET_BUILD_VARIANT),user)
WITH_SU := true
endif

# Where an overlay directory stands in PRODUCT_PACKAGE_OVERLAYS decides who wins a resource that two of
# them define: Soong gives the earlier directory the higher priority, and inherit-product expands the
# inherited list where the call stands, so a directory added after the calls below ranks under LineageOS's
# and Cuttlefish's. The directory with the default wallpaper, which LineageOS also ships, is therefore
# listed here and no other. The target-files verifier reads the built framework overlay for the result.
PRODUCT_PACKAGE_OVERLAYS += device/kernarium/andarium/overlay-priority

$(call inherit-product, device/google/cuttlefish/vsoc_arm64_pgagnostic/phone/aosp_cf.mk)
$(call inherit-product, hardware/interfaces/audio/aidl/default/audio_effects.mk)
$(call inherit-product, vendor/lineage/config/common_full_tablet_wifionly.mk)

# The inherited desktop product installs the complete historical AOSP sound
# library. Keep its compact alarm, notification, and UI defaults, but omit the
# legacy ringtone banks: this product has no telephony stack and the files
# otherwise crowd useful app payloads out of the fixed product image.
PRODUCT_COPY_FILES_EXCLUDE += \
    frameworks/base/data/sounds/newwavelabs/% \
    frameworks/base/data/sounds/ringtones/%

# LineageOS's recovery also trusts the public LineageOS release certificate, so
# the project's own builds can be sideloaded. This product is signed with its
# owner's key alone: the recovery and the system trust that key and no other.
PRODUCT_EXTRA_RECOVERY_KEYS :=

PRODUCT_PACKAGES_EXCLUDE += cuttlefish_sensor_injection
PRODUCT_COPY_FILES += \
    device/kernarium/andarium/sensors/hals.conf:$(TARGET_COPY_OUT_VENDOR)/etc/sensors/hals.conf \
    frameworks/native/data/etc/android.hardware.sensor.accelerometer.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.sensor.accelerometer.xml \
    frameworks/native/data/etc/android.hardware.sensor.gyroscope.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.sensor.gyroscope.xml

PRODUCT_NAME := lineage_andarium
PRODUCT_DEVICE := andarium
PRODUCT_BRAND := Andarium
PRODUCT_MANUFACTURER := Kernarium
PRODUCT_MODEL := Andarium Virtual Device

# LineageOS makes its debug variant not debuggable (any non-empty value of this
# variable counts as set) and always demands ADB authorization. The diagnostics
# variant of this product is debuggable like the AOSP debug build it replaces:
# userdebug has ro.debuggable=1. The user variant, the default and the only
# release, is not. adbd's boot policy (ro.boot.kernarium.adb_auth) decides
# authorization per boot, and on a userdebug build the root service starts with
# rooted debugging enabled only when that policy turns authorization off.
PRODUCT_NOT_DEBUGGABLE_IN_USERDEBUG :=

# The LineageOS updater polls a server for a device this project does not
# publish. The remaining apps have nothing to work with: no recorder input,
# no NFC wallet, no fastboot
# transport, and Canvas is the largest app for the least use. The Profiles app
# has no hardware triggers to act on here. DeskClock and EmergencyInfo leave
# with the other absent-hardware packages below.
PRODUCT_PACKAGES_EXCLUDE += \
    Canvas \
    fastbootd \
    Profiles \
    QuickAccessWallet \
    Recorder \
    Updater
PRODUCT_COPY_FILES_EXCLUDE += \
    vendor/lineage/prebuilt/common/etc/init/init.lineage-updater.rc:$(TARGET_COPY_OUT_SYSTEM_EXT)/etc/init/init.lineage-updater.rc

# Every APEX carries an EROFS payload compressed like the partitions are: the
# same compressor and cluster size, not apexer's lz4hc and 4 KiB. The .apex
# files themselves are stored uncompressed in the partitions (config/
# erofs_compress_hints.txt), so apexd's loop devices read them with direct I/O
# and their pages are cached once. The Cuttlefish base already sets
# OVERRIDE_PRODUCT_COMPRESSED_APEX to false, which keeps the payloads out of a
# compressed container. The hints keep the init scripts and VINTF fragments
# uncompressed.
PRODUCT_DEFAULT_APEX_PAYLOAD_TYPE := erofs
PRODUCT_DEFAULT_APEX_PAYLOAD_EROFS_COMPRESSOR := $(UML_ANDROID_EROFS_COMPRESSOR)
PRODUCT_DEFAULT_APEX_PAYLOAD_EROFS_PCLUSTER_SIZE := $(UML_ANDROID_EROFS_PCLUSTER_SIZE)
PRODUCT_DEFAULT_APEX_PAYLOAD_EROFS_COMPRESS_HINTS := device/kernarium/andarium/config/erofs_apex_payload_hints.txt

# The kernel runs 4 KiB pages. The userspace stays page-agnostic, so a 16 KiB
# maximum alignment keeps every 64-bit ELF valid on a kernel of either size.
# BoardConfig.mk clears the inherited TARGET_BOOTS_16K, because the parent
# product assigns it after this file is read.
PRODUCT_MAX_PAGE_SIZE_SUPPORTED := 16384
PRODUCT_NO_BIONIC_PAGE_SIZE_MACRO := true
PRODUCT_CHECK_PREBUILT_MAX_PAGE_SIZE := true
PRODUCT_16K_DEVELOPER_OPTION := false

PRODUCT_BUILD_VENDOR_DLKM_IMAGE := false
PRODUCT_BUILD_ODM_DLKM_IMAGE := false
PRODUCT_BUILD_SYSTEM_DLKM_IMAGE := false
PRODUCT_USE_DYNAMIC_PARTITIONS := false
PRODUCT_USE_DYNAMIC_PARTITION_SIZE := false
PRODUCT_BUILD_SUPER_PARTITION := false
PRODUCT_BUILD_SUPER_EMPTY_IMAGE := false
PRODUCT_BUILD_SYSTEM_OTHER_IMAGE := false
PRODUCT_VIRTUAL_AB_OTA := false
PRODUCT_VIRTUAL_AB_COMPRESSION := false
PRODUCT_VIRTUAL_AB_COMPRESSION_METHOD :=
PRODUCT_VIRTUAL_AB_COMPRESSION_FACTOR :=
PRODUCT_OTA_FORCE_NON_AB_PACKAGE := false
AB_OTA_POSTINSTALL_CONFIG :=
PRODUCT_BUILD_RECOVERY_IMAGE := true

# Replace generic Cuttlefish boot policy modules with files owned by this
# exact-synced product overlay. The inherited product init script declares only
# tombstone_transmit, which this product does not install. ueventd reads vendor
# rules only from /vendor/etc/ueventd.rc.
PRODUCT_PACKAGES_EXCLUDE += \
    device_google_cuttlefish_shared_config_init_product_rc \
    device_google_cuttlefish_uml_config_init_vendor_rc \
    device_google_cuttlefish_uml_config_ueventd_rc \
    fstab.uml \
    fstab.uml.vendor_ramdisk
# The first source for a destination wins, including inherited copy entries.
PRODUCT_COPY_FILES := \
    device/kernarium/andarium/config/init.recovery.rc:$(TARGET_COPY_OUT_RECOVERY)/root/init.recovery.cutf_cvm.rc \
    $(PRODUCT_COPY_FILES)
PRODUCT_COPY_FILES += \
    device/google/cuttlefish/shared/config/init.recovery.rc:$(TARGET_COPY_OUT_RECOVERY)/root/init.recovery.cuttlefish.rc \
    device/kernarium/andarium/tools/kernarium_addons.sh:$(TARGET_COPY_OUT_RECOVERY)/root/system/bin/kernarium_addons.sh \
    device/kernarium/andarium/config/init.vendor.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/init.kernarium.rc \
    device/kernarium/andarium/config/ueventd.rc:$(TARGET_COPY_OUT_VENDOR)/etc/ueventd.rc \
    device/kernarium/andarium/config/fstab.uml:$(TARGET_COPY_OUT_VENDOR)/etc/fstab.uml \
    device/kernarium/andarium/config/fstab.uml:$(TARGET_COPY_OUT_VENDOR_RAMDISK)/first_stage_ramdisk/fstab.uml \
    device/kernarium/andarium/config/audio_policy_configuration.xml:$(TARGET_COPY_OUT_VENDOR)/etc/audio_policy_configuration.xml \
    device/kernarium/andarium/config/primary_audio_policy_configuration.xml:$(TARGET_COPY_OUT_VENDOR)/etc/primary_audio_policy_configuration.xml \
    frameworks/av/services/audiopolicy/config/audio_policy_volumes.xml:$(TARGET_COPY_OUT_VENDOR)/etc/audio_policy_volumes.xml \
    frameworks/av/services/audiopolicy/config/default_volume_tables.xml:$(TARGET_COPY_OUT_VENDOR)/etc/default_volume_tables.xml \
    frameworks/av/services/audiopolicy/config/r_submix_audio_policy_configuration.xml:$(TARGET_COPY_OUT_VENDOR)/etc/r_submix_audio_policy_configuration.xml

# Remove obsolete first-party applications and packages backed by hardware
# that the Darwin UML machine does not expose. Providers and framework APIs
# useful to ordinary third-party applications remain installed, and so does
# sgdisk: vold executes /system/bin/sgdisk to scan and partition any disk it
# manages, such as the virtual disk of `sm set-virtual-disk`.
#
# The Wi-Fi HAL and the supplicant stay, because the kernel's virt_wifi gives
# the guest a Wi-Fi station. wificond does not come back: the release
# configuration retires it (RELEASE_DISABLE_WIFICOND), and the Wi-Fi service
# then drives nl80211 itself. What Cuttlefish adds around the stack does not
# stay: com.google.cf.wifi holds Cuttlefish's own network setup tools
# (rename_netiface, setup_wifi and the mac80211 radios), which
# kernarium_net_setup replaces, and its feature files, which come from the
# device tree below. CuttlefishWifiOverlay turns on MAC randomization that
# virt_wifi cannot do (KernariumWifiOverlay replaces it), and the tethering
# overlay serves a tethering stack that has no upstream here.
#
# DeviceDiagnostics goes too, to turn Android's trade-in mode off: its boot
# receiver asks TradeInModeService to start on a first boot that has not been
# set up, which turns USB debugging on and restarts adbd twice (the virtual
# Wi-Fi stops the mode again at once). The service has no configuration switch
# and answers only to a package that holds ENTER_TRADE_IN_MODE. DeviceDiagnostics
# is the one that asks at boot (the shell package holds the permission too, for
# what a person types over adb), so the product without it never enters the
# mode by itself. A virtual device has no trade-in. The verifier asserts both.
KERNARIUM_REMOVED_PACKAGES := \
    BasicDreams \
    BluetoothMidiService \
    BookmarkProvider \
    Browser2 \
    CFSatelliteService \
    CuttlefishTetheringOverlay \
    CuttlefishWifiOverlay \
    Calendar \
    CallLogBackup \
    Camera2 \
    CameraExtensionsProxy \
    CarrierConfig \
    CarrierDefaultApp \
    CellBroadcastLegacyApp \
    Contacts \
    CuttlefishService \
    DeskClock \
    DeviceAsWebcam \
    DeviceDiagnostics \
    DynamicSystemInstallationService \
    Dialer \
    EmergencyInfo \
    EyesFreeVidService \
    Gallery2 \
    ImsServiceEntitlement \
    Jelly \
    MmsService \
    Music \
    MusicFX \
    ONS \
    PhotoTable \
    QuickSearchBox \
    SatelliteClient \
    SimAppDialog \
    Stk \
    TeleService \
    Telecom \
    TelecomShim \
    TelephonyProvider \
    android.hardware.biometrics.face-service.default \
    android.hardware.biometrics.fingerprint-service.default \
    android.hardware.motioncontext-service.default \
    androidx.camera.extensions.impl \
    com.android.cellbroadcast \
    com.android.compos \
    com.android.hardware.authsecret \
    com.android.hardware.biometrics.face.virtual \
    com.android.hardware.biometrics.fingerprint.virtual \
    com.android.hardware.graphics.composer.ranchu \
    com.android.hardware.contexthub \
    com.android.hardware.gnss \
    com.android.hardware.input.processor \
    com.android.hardware.net.nlinterceptor \
    com.android.hardware.rebootescrow \
    com.android.hardware.secure_element \
    com.android.hardware.security.authgraph \
    com.android.hardware.security.secretkeeper \
    com.android.hardware.tetheroffload \
    com.android.hardware.usb \
    com.android.hardware.vibrator \
    com.android.vndk.v31 \
    com.android.vndk.v32 \
    com.android.vndk.v33 \
    com.android.vndk.v34 \
    com.google.emulated.camera.provider.hal \
    com.google.emulated.camera.provider.hal.v4l2 \
    com.google.cf.confirmationui \
    com.google.cf.health \
    com.google.cf.bt \
    com.google.cf.identity \
    com.google.cf.ir \
    com.google.cf.wifi \
    cuttlefish_telephony_satellite_configs \
    gsi_tool \
    gsid \
    android.hardware.health-service.cuttlefish_recovery \
    messaging \
    pmg_daemon \
    sample_camera_extensions.xml \
    snapshotctl \
    snapuserd \
    snapuserd_ramdisk \
    socket_vsock_proxy \
    tombstone_transmit \
    update_engine \
    update_engine_client \
    update_verifier \
    wificond \
    wificond_compat_symlink_module
PRODUCT_PACKAGES_EXCLUDE += $(KERNARIUM_REMOVED_PACKAGES)

# The inherited Cuttlefish product also asks for modules this tree does not
# define. AOSP ignores such requests; LineageOS requires every requested
# package to exist, so name them here instead of switching the check off.
PRODUCT_PACKAGES_EXCLUDE += \
    libGoldfishProfiler \
    metrics_helper \
    sleep

# The keyboard (LatinIME) and ThemePicker come from the LineageOS product
# chain. resize2fs grows the compact userdata filesystem
# online after the host expands its partition, once /data is mounted
# (init.vendor.rc, post-fs-data).
PRODUCT_PACKAGES += \
    android.hardware.health-service.example \
    android.hardware.health-service.example_recovery \
    e2fsck \
    resize2fs

# First boot compiles nothing. Soong preopts the applications it installs, but
# never an application inside an APEX. tools/precompile-first-boot-apps.py
# compiles the rest after a first build
# pass; build-aosp.sh hands its PRODUCT_COPY_FILES fragment to the second pass
# through this variable, a path relative to the workspace root.
ifneq ($(LINEAGE24_FIRST_BOOT_OAT_MK),)
include $(LINEAGE24_FIRST_BOOT_OAT_MK)
endif

# Replace the handheld feature declaration and remove optional feature files
# for absent hardware. This keeps PackageManager truthful for sideloaded apps.
# The guest declares android.hardware.wifi, which virt_wifi provides, and not
# android.hardware.ethernet: eth0 is the management NIC, and the framework would
# otherwise start Ethernet management on it. virt_wifi is a station without
# peer-to-peer, so android.hardware.wifi.direct stays out, and so do Aware and
# RTT, which the interface combinations do not offer. Passpoint waits for the
# first Wi-Fi CTS run.
PRODUCT_COPY_FILES_EXCLUDE += \
    frameworks/native/data/etc/handheld_core_hardware.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/handheld_core_hardware.xml \
    frameworks/native/data/etc/android.hardware.biometrics.face.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.biometrics.face.xml \
    frameworks/native/data/etc/android.hardware.bluetooth.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.bluetooth.xml \
    frameworks/native/data/etc/android.hardware.bluetooth_le.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.bluetooth_le.xml \
    frameworks/native/data/etc/android.hardware.fingerprint.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.fingerprint.xml \
    frameworks/native/data/etc/android.hardware.camera.concurrent.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.camera.concurrent.xml \
    frameworks/native/data/etc/android.hardware.camera.flash-autofocus.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.camera.flash-autofocus.xml \
    frameworks/native/data/etc/android.hardware.camera.front.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.camera.front.xml \
    frameworks/native/data/etc/android.hardware.camera.full.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.camera.full.xml \
    frameworks/native/data/etc/android.hardware.camera.raw.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.camera.raw.xml \
    frameworks/native/data/etc/android.hardware.consumerir.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.consumerir.xml \
    frameworks/native/data/etc/android.hardware.ethernet.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.ethernet.xml \
    frameworks/native/data/etc/android.hardware.location.gps.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.location.gps.xml \
    frameworks/native/data/etc/android.hardware.usb.accessory.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.usb.accessory.xml \
    frameworks/native/data/etc/android.hardware.usb.host.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.usb.host.xml \
    frameworks/native/data/etc/android.hardware.uwb.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.uwb.xml \
    frameworks/native/data/etc/android.hardware.wifi.direct.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.wifi.direct.xml \
    frameworks/native/data/etc/android.hardware.wifi.passpoint.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.wifi.passpoint.xml \
    frameworks/native/data/etc/android.software.verified_boot.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.software.verified_boot.xml
PRODUCT_COPY_FILES += \
    device/kernarium/andarium/config/kernarium_core_hardware.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/handheld_core_hardware.xml

# The Vulkan HAL is Mesa's Venus driver built from this project's pinned guest
# Mesa source. Its generated Soong module names are scoped with a venus_
# prefix so they cannot collide with the AOSP external/mesa3d modules. The
# feature declarations the removed Cuttlefish Vulkan APEX used to install
# come from the device tree instead, at the level this driver supports. No
# Vulkan dEQP level is declared: the driver has not been qualified. The
# loader finds the module by ro.hardware.vulkan, whose one writer is the boot
# command line's androidboot.hardware.vulkan, as for ro.hardware.egl below.
PRODUCT_PACKAGES_EXCLUDE += com.google.cf.vulkan
PRODUCT_PACKAGES += vulkan.virtio

# The EGL and GLES libraries are Mesa's Virgl driver from the same source and
# generated port. The platform EGL loader finds them in /vendor/lib64/egl by the
# ro.hardware.egl suffix; the gallium driver they link lies in /vendor/lib64.
# The inherited Cuttlefish Virgl configuration would add the AOSP
# external/mesa3d libGLES_mesa instead. The boot command line's
# androidboot.hardware.egl is the property's one writer: the product init
# script copies it, like the Vulkan and gralloc selections, at early-init, and
# that setprop fails if a vendor property has already set it. No vendor
# property may name any of the three.
#
# That script replaces the inherited Cuttlefish init_graphics.vendor.rc, which
# also copies the goldfish composer mode and the ANGLE feature overrides. This
# product has neither, their androidboot sources never exist, and each copy
# failed at every boot.
PRODUCT_PACKAGES_EXCLUDE += \
    device_google_cuttlefish_shared_config_init_graphics_vendor_rc \
    libGLES_mesa
PRODUCT_PACKAGES += \
    libEGL_kernarium \
    libGLESv1_CM_kernarium \
    libGLESv2_kernarium

# Mesa reads a buffer's DRM format, modifier and plane layout through the
# gralloc0 interface of minigbm, the product's allocator. The passthrough
# gralloc.default module cannot answer those queries, so Mesa would fall
# back to guessing and the driver could not describe the buffers the window
# system hands it. The module is a same-process HAL like the driver above,
# selected through ro.hardware.gralloc by androidboot.hardware.gralloc.
PRODUCT_PACKAGES += gralloc.minigbm
# The boot command line declares OpenGL ES 3.2 (androidboot.opengles.version).
# The driver lists GL_ANDROID_extension_pack_es31a on every ES 3.1 or later
# context, so the product declares the extension pack with it, and the dEQP
# level is the one whose EGL and GLES lists passed whole; the target-files
# verifier pins both.
PRODUCT_COPY_FILES += \
    frameworks/native/data/etc/android.hardware.vulkan.level-1.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.vulkan.level-1.xml \
    frameworks/native/data/etc/android.hardware.vulkan.compute-0.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.vulkan.compute-0.xml \
    frameworks/native/data/etc/android.hardware.vulkan.version-1_4.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.vulkan.version-1_4.xml \
    frameworks/native/data/etc/android.hardware.opengles.aep.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.opengles.aep.xml \
    frameworks/native/data/etc/android.software.opengles.deqp.level-latest.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.software.opengles.deqp.level-latest.xml

# A Vulkan window-system smoke test for this product. It owns a
# SurfaceFlinger layer, wraps it through VK_KHR_android_surface, and clears
# and presents a swapchain, so a run exercises the gralloc buffers the
# platform loader hands the driver through VK_ANDROID_native_buffer.
PRODUCT_PACKAGES += kernarium_vk_present
PRODUCT_ARTIFACT_PATH_REQUIREMENT_ALLOWED_LIST += system/bin/kernarium_vk_present

# eth0 is the management NIC adb is reached on; the framework sees the virtual
# Wi-Fi built on it. This tool configures both before the framework starts
# (init.vendor.rc runs it at post-fs-data).
PRODUCT_PACKAGES += kernarium_net_setup

# The Wi-Fi module's resources are overlaid by KernariumWifiOverlay
# (rro/KernariumWifiOverlay): virt_wifi cannot change its MAC address, so the
# framework must not randomize it.
PRODUCT_PACKAGES += KernariumWifiOverlay

# PinnerService locks the home app's APK and its compiled code into memory,
# about 54 MiB at idle. KernariumPinnerOverlay (rro/KernariumPinnerOverlay)
# sets the home pin size to zero and leaves the WebView pin as it was.
PRODUCT_PACKAGES += KernariumPinnerOverlay

# Once boot completes, a script saves the virtual Wi-Fi network (VirtWifi, open)
# the first time only. It does not turn Wi-Fi on, and a network the user forgets
# stays forgotten. It runs from system_ext in a core domain of its own.
PRODUCT_PACKAGES += kernarium_wifi_network_script

# Cached apps the system starts at boot (privacy sandbox, backup, key
# provisioning, domain verification, Health Connect) keep memory until the low
# memory killer wants it. Once boot has settled this script kills the cached
# processes of a reviewed list of packages and nothing else; the apps start again
# when something uses them.
PRODUCT_PACKAGES += kernarium_reclaim_boot_apps_script

# A new guest starts on GMT and Android's automatic time zone has no source in
# it, so the host application passes its own time zone at every start
# (ro.boot.kernarium.timezone). Once boot completes this script applies it
# while "Set time zone automatically" is on, and leaves a zone the user chose
# with it off alone. It runs from system_ext in a core domain of its own.
PRODUCT_PACKAGES += kernarium_time_zone_script

# A Vulkan hardware-buffer import check: it fills gralloc buffers of several
# formats and widths through the CPU, imports each into Vulkan and reads it
# back, so a row pitch the driver cannot import or the renderer misreads fails
# the run.
PRODUCT_PACKAGES += kernarium_vk_ahb_import
PRODUCT_ARTIFACT_PATH_REQUIREMENT_ALLOWED_LIST += system/bin/kernarium_vk_ahb_import

# A YUV hardware-buffer round-trip check: it writes NV12, P010 and YV12 buffers
# of even and odd sizes whole and then by a partial lock, and reads them back
# through the host copy, so a layout the guest and the renderer read
# differently fails the run.
PRODUCT_PACKAGES += kernarium_ahb_yuv_roundtrip
PRODUCT_ARTIFACT_PATH_REQUIREMENT_ALLOWED_LIST += system/bin/kernarium_ahb_yuv_roundtrip

# An RGBA hardware-buffer lock check: tall buffers of widths whose rows gralloc
# pads are written by the GPU and read by the CPU, and written by the CPU and
# read by the GPU, at the stride gralloc reports, and the locks of the padded
# widths are timed against the unpadded ones, so a lock that costs a transfer
# for each row fails the run.
PRODUCT_PACKAGES += kernarium_ahb_rgba_lock
PRODUCT_ARTIFACT_PATH_REQUIREMENT_ALLOWED_LIST += system/bin/kernarium_ahb_rgba_lock

# An EGL config check: it lists the configs, picks the one the hardware renderer
# asks eglChooseConfig for (RGBA8888, no depth, eight bits of stencil) and
# stencils in a pbuffer of it, so a guest that stores a window's stencil beside
# a depth plane it never reads, or a stencil that does not stencil, fails the
# run.
PRODUCT_PACKAGES += kernarium_egl_configs
PRODUCT_ARTIFACT_PATH_REQUIREMENT_ALLOWED_LIST += system/bin/kernarium_egl_configs

# Hardware video encoding and decoding. The host's VideoToolbox encoders and
# decoders reach the guest as V4L2 stateful devices, and external/v4l2_codec2
# exposes them through Codec2: its service is the vendor Codec2 store beside the
# software one. The service brings the vendor variants of the libraries it
# links, the plugin store among them; naming one of those here would install its
# core variant under /system, which the generic system artifact path
# requirement refuses. The XML lists the encoders and the HEVC and H.264
# decoders, and the properties enable exactly those components; it also updates
# the limits of the software HEVC and VP9 decoders, which advertise less than
# they decode, to 3840x2160. The store
# admits as many instances as the properties allow and reports the pixel rate
# the host sustains as the capacity of the real-time streams of each direction.
# That capacity is the largest performance point the XML publishes: 3840x2160 at
# 13 frames per second is 107827200 luma samples per second for the encoders,
# and 3840x2160 at 55 frames per second is 456192000 for the decoders (CTS
# wants the largest point to use at least 60% of the capacity). A decoder keeps
# its pool of decoded pictures in the guest's 8 GiB, about 0.9 GiB for a 4K
# stream, so four decoders may run at once where the encoders allow eight. The
# extended policy adds the calls the service's seccomp policy lacks for the V4L2
# device and for the crash handler, and ueventd gives the nodes to the group the
# service joins.
PRODUCT_SOONG_NAMESPACES += external/v4l2_codec2
PRODUCT_PACKAGES += android.hardware.media.c2-service-v4l2
PRODUCT_COPY_FILES += \
    device/kernarium/andarium/config/media_codecs_c2.xml:$(TARGET_COPY_OUT_VENDOR)/etc/media_codecs_c2.xml \
    device/kernarium/andarium/config/media_c2_extended_seccomp_policy:$(TARGET_COPY_OUT_VENDOR)/etc/seccomp_policy/android.hardware.media.c2-extended-seccomp_policy
PRODUCT_VENDOR_PROPERTIES += \
    ro.vendor.v4l2_codec2.encoder.supported.h264=true \
    ro.vendor.v4l2_codec2.encoder.supported.hevc=true \
    ro.vendor.v4l2_codec2.encode_concurrent_instances=8 \
    ro.vendor.v4l2_codec2.video_pixel_rate=108000000 \
    ro.vendor.v4l2_codec2.decoder.supported.h264=true \
    ro.vendor.v4l2_codec2.decoder.supported.hevc=true \
    ro.vendor.v4l2_codec2.decode_concurrent_instances=4 \
    ro.vendor.v4l2_codec2.video_decode_pixel_rate=456192000

PRODUCT_PACKAGE_OVERLAYS += device/kernarium/andarium/overlay

# The virtio-gpu device paces the display with a vblank timer, so a present
# fence signals when the frame is shown. The inherited Cuttlefish graphics
# configuration marks the fences unreliable for a host that sends frames as fast
# as it can; with the property absent, SurfaceFlinger takes present timestamps
# from the fences (service.sf.present_timestamp=1) and the Vulkan loader exposes
# VK_GOOGLE_display_timing. A filter over PRODUCT_VENDOR_PROPERTIES cannot remove
# an inherited value (inherit-product merges the parent's variables later), and
# a second assignment of the key is a duplicate that the build refuses, so the
# vendor build.prop denylist drops the property. The target-files verifier
# rejects it when it is true.
PRODUCT_VENDOR_PROPERTY_BLACKLIST += ro.vendor.hwc.drm.present_fence_not_reliable

# The inherited Cuttlefish product also states the SoC identity in the vendor
# properties, as its product manufacturer and device (Google and
# vsoc_arm64_pgagnostic), which Build.SOC_MANUFACTURER and Build.SOC_MODEL then
# report. The denylist drops both for the same reason, and config/odm.prop,
# which BoardConfig.mk hands to the build as TARGET_ODM_PROP, states the
# virtual CPU's. The target-files verifier requires the odm values and no
# ro.soc.* in the vendor build.prop, so that each property has one source.
PRODUCT_VENDOR_PROPERTY_BLACKLIST += ro.soc.manufacturer ro.soc.model

# ADB reaches the guest over vsock (and over TCP when the launch has a host
# forward) even though this machine has no USB controller. A user build retains
# the stock shell privilege boundary; a userdebug build also lets `adb root`
# restart adbd as root, so whoever can reach the port without authorization is
# root in the guest. Apple hosts select authorization through the immutable
# ro.boot.kernarium.adb_auth property on each boot, and adbd takes that boot
# policy in place of the build type's ro.adb.secure. The property itself stays
# the build type's value: Settings hides "Revoke USB debugging authorizations"
# while it is false, and the user could no longer revoke the computers they
# allowed. The inherited Cuttlefish user block sets it to 0 in the product
# partition, whose build.prop is read after system's, so the Cuttlefish topic
# (route p0001) drops that entry at its source when UML_ANDROID_KEEP_ADB_SECURE
# is true (set above). Neither this file nor BoardConfig.mk can: inherit-product
# merges an inherited list after the product's own entries, and the product
# property lists are read-only by the time the board configuration runs.
#
# USB debugging is off on a fresh data partition: persist.sys.usb.config, which
# AdbService reads at every boot to set adb_enabled, has no product default.
# The filter drops an entry this product's own lines add, and the target-files
# verifier rejects any build.prop that sets the property. adbd serves the host
# application's key whatever the setting; any other key needs debugging on.
PRODUCT_PRODUCT_PROPERTIES := $(filter-out \
    persist.sys.usb.config=%,$(PRODUCT_PRODUCT_PROPERTIES))

# The WebView provider declares use32bitAbi. Left alone, that makes its 32-bit
# libraries primary, and every WebView renderer, including those of 64-bit
# applications, a 32-bit process. Keep the 64-bit ABI primary: 32-bit
# applications still load the 32-bit WebView library in their own process and
# talk to a 64-bit renderer.
PRODUCT_PRODUCT_PROPERTIES += \
    ro.config.ignore_use32bitabi=true

# The Virtio sound transport has no MMAP or exclusive hardware path. These
# read-only defaults seed a fresh Settings database; persisted user volume
# choices continue to take precedence after first boot.
PRODUCT_PRODUCT_PROPERTIES += \
    sys.use_memfd=true \
    aaudio.mmap_policy=1 \
    aaudio.mmap_exclusive_policy=1 \
    ro.config.vc_call_vol_steps=15 \
    ro.config.vc_call_vol_default=15 \
    ro.config.media_vol_default=15 \
    ro.config.alarm_vol_default=7 \
    ro.config.system_vol_default=7 \
    ro.config.assistant_vol_default=15 \
    audio.timecheck.timeout_duration_ms=300000 \
    audio.timecheck.second_chance_duration_ms=200000
PRODUCT_SYSTEM_EXT_PROPERTIES += \
    ro.audio.ihaladaptervendorextension_enabled=true

# The primary audio HAL opens its ALSA streams with four periods of one HAL
# buffer each (alsa_utils divides the multiplied buffer by the count): a
# 1024-frame output ring at the primary module's 5 ms buffer (route p0005). The
# boot command line lowers the Virtio sound driver's minimum period to 5 ms to
# admit it.
PRODUCT_VENDOR_PROPERTIES += \
    ro.hardware.audio.tinyalsa.period_count=4 \
    ro.hardware.audio.tinyalsa.period_size_multiplier=4

# The guest boots straight to the home screen, and its swipe lock screen stays
# available. LockSettingsService writes lockscreen.disabled=1 for user 0 when it
# creates its database, which a fresh /data does on the first boot; the setting
# can then be changed with `locksettings set-disabled` or the Settings app.
# config_disableLockscreenByDefault is false for that reason (the overlay's
# core/res config.xml). The standalone launcher gives every release a new /data.
# The Setup Wizard's screen lock page is hidden, so a fresh guest keeps this
# default until a person sets a lock in Settings.
PRODUCT_PRODUCT_PROPERTIES += \
    ro.lockscreen.disable.default=true

# apexd pins an updated APEX as a device-mapper linear table over the block device that
# holds /data (Early Activation; it bypasses dm-default-key on devices with metadata
# encryption). Userdata here is an unencrypted ext4 filesystem mounted straight from its
# partition, and that mount holds the partition exclusively, so the table load fails with
# EBUSY and every staged APEX install is rejected. GSI and DSU turn pinning off with this
# same property: apexd then stages through /data/app-staging and init keeps two mount
# namespaces (ro.init.mnt_ns.count 2). The target-files verifier requires the property.
PRODUCT_PRODUCT_PROPERTIES += \
    apexd.config.use_fiemap=false

# lmkd ends the cached app that holds the most host graphics memory when the host
# reports pressure in /sys/class/drm/card0/gpu_memory_report (route p0027). The code
# is off unless this is set, and does nothing on a kernel without the file. The
# platform's property_contexts label the name as an lmkd setting (route p0020).
PRODUCT_PRODUCT_PROPERTIES += \
    ro.lmk.gpu_reclaim=true

PRODUCT_IGNORE_ALL_ANDROIDMK := true
