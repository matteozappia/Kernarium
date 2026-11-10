#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Run the whole producer on one x86_64 Linux builder: synchronize the source,
# apply the series, build the target files, sign them and publish the release.
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ANDROID_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
METADATA="$ANDROID_ROOT/metadata/lineage.env"

WORK_ROOT=
KERNEL_ARTIFACT=
SIGNING_KEYS=
SDK_SETTINGS=
RELEASE_ID=
BUILD_NUMBER=
JOBS=

# shellcheck disable=SC1090
. "$SCRIPT_DIR/common.sh"

usage()
{
	cat <<'EOF'
Usage: android/lineage-24/build/build-release.sh \
       --work-root ABSOLUTE_PATH \
       --kernel-artifact ABSOLUTE_PATH \
       --signing-keys ABSOLUTE_PATH \
       --sdk-settings ABSOLUTE_PATH \
       --release-id ID --build-number N [--jobs N]

Run locally on the x86_64 Linux builder, from a clean checkout of this
repository. WORK_ROOT/aosp is an initialized Repo workspace. It runs prepare-sources.sh, apply-aosp-patches.sh, build-aosp.sh
and publish-release.sh in order, each of which stays the owner of its step,
and leaves the release under WORK_ROOT/releases. A second run reuses the
source and the build output under WORK_ROOT.

--kernel-artifact is the published Android kernel artifact the Mac built.
--signing-keys is the release key directory, outside this checkout and
WORK_ROOT. One that does not exist is created (mode 0700) with a new key set,
and keys the build newly needs are added to an existing one. Keep it: a guest
accepts a later release only when the same keys signed it.
--sdk-settings is the SDKSettings.json of the Darwin SDK that built the
runtime; the release records its version as provenance and uses nothing else
of the SDK.
EOF
}

while [ "$#" -gt 0 ]; do
	case "$1" in
	--work-root | --kernel-artifact | --signing-keys | --sdk-settings | --release-id | --build-number | --jobs)
		[ "$#" -ge 2 ] || fail "$1 requires a value"
		case "$1" in
		--work-root) WORK_ROOT=$2 ;;
		--kernel-artifact) KERNEL_ARTIFACT=$2 ;;
		--signing-keys) SIGNING_KEYS=$2 ;;
		--sdk-settings) SDK_SETTINGS=$2 ;;
		--release-id) RELEASE_ID=$2 ;;
		--build-number) BUILD_NUMBER=$2 ;;
		--jobs) JOBS=$2 ;;
		esac
		shift 2
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		fail "unknown argument: $1"
		;;
	esac
done

for required in WORK_ROOT KERNEL_ARTIFACT SIGNING_KEYS SDK_SETTINGS RELEASE_ID BUILD_NUMBER; do
	[ -n "${!required}" ] || { usage >&2; fail "missing a required argument"; }
done
absolute_path "work root" "$WORK_ROOT"
absolute_path "kernel artifact" "$KERNEL_ARTIFACT"
absolute_path "signing key directory" "$SIGNING_KEYS"
absolute_path "SDK settings" "$SDK_SETTINGS"
[ "$(uname -s)" = Linux ] && [ "$(uname -m)" = x86_64 ] ||
	fail "builder host must be x86_64 Linux"
[ -d "$KERNEL_ARTIFACT" ] || fail "kernel artifact does not exist: $KERNEL_ARTIFACT"
[ -f "$SDK_SETTINGS" ] || fail "SDK settings do not exist: $SDK_SETTINGS"
case "$SIGNING_KEYS/" in
"$WORK_ROOT"/* | "$(CDPATH= cd -- "$ANDROID_ROOT/../.." && pwd)"/*)
	fail "the signing key directory must be outside the work root and this checkout"
	;;
esac
case "$JOBS" in
'') JOBS=$(getconf _NPROCESSORS_ONLN) ;;
*[!0-9]* | 0) fail "--jobs must be a positive integer" ;;
esac

# shellcheck disable=SC1090
. "$METADATA"

AOSP_SOURCE="$WORK_ROOT/aosp"
OUT_DIR="$AOSP_SOURCE/out-andarium"
RELEASE_ROOT="$WORK_ROOT/releases"
SDK_DIR="$WORK_ROOT/darwin-sdk"
DISK_DIR="$WORK_ROOT/disk-$RELEASE_ID"
mkdir -p "$RELEASE_ROOT" "$SDK_DIR"
cp "$SDK_SETTINGS" "$SDK_DIR/SDKSettings.json"

[ -d "$AOSP_SOURCE/.repo" ] ||
	fail "WORK_ROOT/aosp is not a Repo workspace: initialize it first"

# A second run finds the series applied, which source preparation refuses as
# a dirty workspace: it then builds what is there.
if [ ! -f "$WORK_ROOT/source-prepared" ]; then
	"$SCRIPT_DIR/prepare-sources.sh" --aosp-source "$AOSP_SOURCE" --jobs "$JOBS"
	"$SCRIPT_DIR/apply-aosp-patches.sh" --aosp-source "$AOSP_SOURCE"
	git -C "$ANDROID_ROOT" rev-parse HEAD >"$WORK_ROOT/source-prepared"
else
	# The overlay may have changed since; a changed series needs a clean
	# workspace, which only a removed marker and reset projects give.
	"$ANDROID_ROOT/tools/check-overlay-sepolicy.py" --overlay "$ANDROID_ROOT/overlay"
	"$ANDROID_ROOT/tools/sync-device-tree.py" --android-root "$ANDROID_ROOT" --workspace "$AOSP_SOURCE"
fi

"$SCRIPT_DIR/build-aosp.sh" --aosp-source "$AOSP_SOURCE" --out "$OUT_DIR" \
	--kernel-artifact "$KERNEL_ARTIFACT" --jobs "$JOBS" --build-number "$BUILD_NUMBER"

TARGET_FILES=$(find "$OUT_DIR/target/product" -path '*/target_files_intermediates/*' \
	-name "${LINEAGE24_PRODUCT}-target_files.zip" -print -quit)
[ -n "$TARGET_FILES" ] || fail "target-files archive is missing under $OUT_DIR"
HOST_BIN="$OUT_DIR/host/linux-x86/bin"

# The key set: the platform keys and one container and payload key for each
# APEX the target files name, as sign_release.py routes them.
if [ ! -d "$SIGNING_KEYS" ]; then
	(umask 077 && mkdir -p "$SIGNING_KEYS")
fi
chmod 0700 "$SIGNING_KEYS"
needed_keys=$(
	python3 -B - "$ANDROID_ROOT/tools" "$TARGET_FILES" <<'EOF'
import re
import sys
import zipfile

sys.path.insert(0, sys.argv[1])
import sign_release

with zipfile.ZipFile(sys.argv[2]) as archive:
    apexkeys = sign_release.read_member(archive, "META/apexkeys.txt")
names = set(sign_release.PLATFORM_KEYS)
payloads = set()
for line in apexkeys.splitlines():
    fields = dict(sign_release.FIELD.findall(line))
    container = fields.get("container_private_key", "")
    if "name" not in fields or container == "PRESIGNED":
        continue
    if container.startswith(sign_release.SECURITY_DIR):
        base = re.sub(r"\.c?apex$", "", fields["name"])
    else:
        base = container.rsplit("/", 1)[-1].removesuffix(".pk8")
    names.add(base)
    payloads.add(base)
for name in sorted(names):
    print("certificate", name)
for name in sorted(payloads):
    print("payload", name)
EOF
)
created_keys=0
while read -r kind name; do
	[ -n "$name" ] || continue
	(
		umask 077
		case "$kind" in
		certificate)
			[ -f "$SIGNING_KEYS/$name.pk8" ] && [ -f "$SIGNING_KEYS/$name.x509.pem" ] && exit 1
			private=$(mktemp "$SIGNING_KEYS/.key.XXXXXX")
			openssl genrsa -out "$private" 4096 2>/dev/null
			openssl req -new -x509 -sha256 -key "$private" -days 10000 \
				-subj "/CN=Andarium release $name" -out "$SIGNING_KEYS/$name.x509.pem"
			openssl pkcs8 -in "$private" -topk8 -outform DER -nocrypt -out "$SIGNING_KEYS/$name.pk8"
			rm -f "$private"
			;;
		payload)
			[ -f "$SIGNING_KEYS/$name.pem" ] && exit 1
			openssl genrsa -out "$SIGNING_KEYS/$name.pem" 4096 2>/dev/null
			;;
		esac
	) && created_keys=$((created_keys + 1))
done <<<"$needed_keys"

CLANG=$(find "$AOSP_SOURCE/prebuilts/clang/host/linux-x86" -maxdepth 3 -path '*/bin/clang' | sort -V | tail -n 1)
[ -n "$CLANG" ] || fail "the AOSP Clang prebuilt is missing"
LINKER="$(dirname "$CLANG")/ld.lld"

"$SCRIPT_DIR/publish-release.sh" \
	--aosp-source "$AOSP_SOURCE" \
	--kernel-artifact "$KERNEL_ARTIFACT" \
	--target-files "$TARGET_FILES" \
	--disk-dir "$DISK_DIR" \
	--darwin-sdk "$SDK_DIR" \
	--clang "$CLANG" \
	--linker "$LINKER" \
	--vintf-checker "$HOST_BIN/check_target_files_vintf" \
	--release-root "$RELEASE_ROOT" \
	--release-id "$RELEASE_ID" \
	--signing-keys "$SIGNING_KEYS" \
	--first-boot-artifacts "$OUT_DIR/first-boot-oat" \
	--mkbootfs "$HOST_BIN/mkbootfs" \
	--mkbootimg "$HOST_BIN/mkbootimg"

printf '%s\n' "published the release under: $RELEASE_ROOT"
[ "$created_keys" -eq 0 ] ||
	printf '%s\n' "created $created_keys signing keys under $SIGNING_KEYS: back the directory up"
