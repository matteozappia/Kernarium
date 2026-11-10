#!/system/bin/sh
# SPDX-License-Identifier: Apache-2.0
#
# Gives an add-on package (a flashable ZIP such as an application suite) the
# writable system, system_ext and product partitions its installer expects.
# The real ones are EROFS on a read-only disk, so each gets an add-on layer
# instead: a sparse ext4 image on userdata that Android mounts under the real
# partition at boot (init.vendor.rc).
#
# Recovery's init script runs `prepare` when a sideload starts and `release`
# when it ends (init.recovery.rc). While a sideload runs, the three
# /dev/block/by-name links name loop devices of the images, so an installer
# that mounts "the system partition" read-write gets the layer:
#
#  - system.img holds what a system-as-root filesystem holds, a system/
#    directory, seeded with the real build.prop (installers read the SDK
#    level from it) and the product and system_ext links;
#  - product.img and system_ext.img hold the partition's own root.
#
# Between sideloads each image keeps its payload in one directory, layer/,
# which exists only when there is a payload: Android's overlay mount names
# that directory, so an image with nothing installed changes nothing. The
# seeded files never reach Android, where a stale build.prop would hide the
# real one after a system update.
#
# Userdata is mounted outside /data, which recovery unmounts before it runs an
# installer, and with one context for every file: recovery's domain may not
# write a data type, and the files it creates carry no label until Android's
# first restorecon gives them kernarium_addons_data_file.

data=/mnt/kernarium_data
store=$data/vendor/kernarium_addons
work=/mnt/kernarium_addons
# The real partitions' device nodes, kept while the links name the layers.
real=/tmp/kernarium_addons
names="system system_ext product"
label=u:object_r:system_file:s0
# Sparse: an image costs what is installed in it. The installer checks the
# free space of the filesystem it mounted, so these are the room it sees.
minimum_free_kib=2097152

log() {
  echo "kernarium_addons: $*" > /dev/kmsg
}

size_of() {
  case "$1" in
    product) echo 4G ;;
    system_ext) echo 1G ;;
    *) echo 512M ;;
  esac
}

settle_owner() {
  chown 0:0 "$1" && chmod 0755 "$1" && chcon "$label" "$1"
}

# Puts an image's payload where the installer looks for it.
unpack() {
  name=$1
  root=$work/$name
  settle_owner "$root" || return 1
  rmdir "$root/lost+found" 2>/dev/null
  if [ "$name" = system ]; then
    if [ -d "$root/layer" ]; then
      mv "$root/layer" "$root/system" || return 1
    fi
    mkdir -p "$root/system" && settle_owner "$root/system" || return 1
    mkdir -p "$work/real" || return 1
    mount -t erofs -o ro "$(readlink "$real/system")" "$work/real" || return 1
    cp "$work/real/system/build.prop" "$root/system/build.prop"
    copied=$?
    umount "$work/real"
    [ "$copied" = 0 ] || return 1
    chcon "$label" "$root/system/build.prop" || return 1
    ln -sfn /product "$root/system/product" || return 1
    ln -sfn /system_ext "$root/system/system_ext" || return 1
  elif [ -d "$root/layer" ]; then
    find "$root/layer" -mindepth 1 -maxdepth 1 -exec mv {} "$root/" \; || return 1
    rmdir "$root/layer" || return 1
  fi
}

# Puts an image's payload back into layer/, or leaves none.
pack() {
  name=$1
  root=$work/$name
  if [ "$name" = system ]; then
    rm -f "$root/system/build.prop" "$root/system/product" "$root/system/system_ext"
    # Backup scripts for an A/B update, which this product does not have.
    rm -rf "$root/system/addon.d"
    if ! rmdir "$root/system" 2>/dev/null; then
      mv "$root/system" "$root/layer" || return 1
    fi
  elif [ -n "$(find "$root" -mindepth 1 -maxdepth 1 ! -name lost+found | head -n 1)" ]; then
    mkdir "$root/layer" && settle_owner "$root/layer" || return 1
    find "$root" -mindepth 1 -maxdepth 1 ! -name layer ! -name lost+found \
      -exec mv {} "$root/layer/" \; || return 1
  fi
}

attach() {
  name=$1
  image=$store/$name.img
  if [ ! -f "$image" ]; then
    rm -f "$image.new"
    truncate -s "$(size_of "$name")" "$image.new" || return 1
    mke2fs -q -F -t ext4 -b 4096 -O ^has_journal -E lazy_itable_init=1 "$image.new" || return 1
    mv "$image.new" "$image" || return 1
  fi
  ln -s "$(readlink -f "/dev/block/by-name/$name")" "$real/$name" || return 1
  loop=$(losetup -sf "$image") || return 1
  echo "$loop" > "$real/$name.loop"
  mkdir -p "$work/$name" || return 1
  mount -t ext4 -o noatime "$loop" "$work/$name" || return 1
  unpack "$name"
  unpacked=$?
  umount "$work/$name"
  [ "$unpacked" = 0 ] || return 1
  ln -sfn "$loop" "/dev/block/by-name/$name"
}

detach() {
  name=$1
  [ -L "$real/$name" ] || return 0
  ln -sfn "$(readlink "$real/$name")" "/dev/block/by-name/$name"
  rm -f "$real/$name"
  # No loop device: the image was never attached.
  [ -f "$real/$name.loop" ] || return 0
  loop=$(cat "$real/$name.loop")
  rm -f "$real/$name.loop"
  # An installer that failed may have left its own mount of the layer.
  umount "$loop" 2>/dev/null
  if mount -t ext4 -o noatime "$loop" "$work/$name"; then
    pack "$name" || log "the $name layer keeps the installer's layout"
    umount "$work/$name"
  fi
  losetup -d "$loop"
}

prepare() {
  # A second sideload in one recovery session finds the layers still offered.
  [ -d "$real" ] && return 0
  mkdir -p "$data" "$work" || return 1
  if ! mountpoint -q "$data"; then
    mount -t ext4 -o noatime,context=u:object_r:kernarium_addons_file:s0 \
      /dev/block/by-name/userdata "$data" || return 1
  fi
  # Android creates /data/vendor on its first boot.
  [ -d "$data/vendor" ] || return 1
  free=$(df -k "$data" | tail -n 1 | tr -s ' ' | cut -d ' ' -f 4)
  [ "${free:-0}" -ge "$minimum_free_kib" ] || return 1
  mkdir -p "$store" && chmod 0700 "$store" || return 1
  mkdir -p "$real" || return 1
  for name in $names; do
    attach "$name" || return 1
  done
}

release() {
  [ -d "$real" ] || return 0
  for name in $names; do
    detach "$name"
  done
  rmdir "$real"
  umount "$data"
}

case "$1" in
  prepare)
    if ! prepare; then
      log "no add-on layers: installers see the read-only partitions"
      release
    fi
    ;;
  release)
    release
    ;;
esac
