#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Synchronize clean builder-local workspaces to the pinned public source inputs.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd)
AOSP_METADATA="$ROOT_DIR/android/lineage-24/metadata/lineage.env"
MESA_VENUS_METADATA="$ROOT_DIR/android/lineage-24/third_party/mesa-venus/metadata.env"
MESA_VENUS_VERIFIER="$ROOT_DIR/android/lineage-24/tools/verify-mesa-venus-source.py"

AOSP_SOURCE=
JOBS=
STAGING=

# shellcheck disable=SC1090
. "$SCRIPT_DIR/common.sh"

usage()
{
	cat <<'EOF'
Usage: android/lineage-24/build/prepare-sources.sh \
       --aosp-source ABSOLUTE_PATH [--jobs N]

Run this command locally on the x86_64 Linux builder. It is the only Android
producer step allowed to synchronize the public LineageOS and guest Mesa
source. The Repo workspace must already exist and be clean. It is synchronized
to the exact commits of the checked base manifest, and needs Git LFS for its
WebView prebuilts. The Venus Vulkan HAL's
Mesa source is materialized at its pinned external commit plus generated local
patch series. No endpoint or transport option is accepted.
EOF
}

cleanup()
{
	if [ -n "${STAGING:-}" ] && [ -d "$STAGING" ]; then
		rm -rf -- "$STAGING"
	fi
}
trap cleanup EXIT HUP INT TERM

pinned_git()
{
	GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C "$STAGING" "$@"
}

# materialize_pinned LABEL DESTINATION VERIFIER REPOSITORY COMMIT TREE BRANCH \
#     [SERIES_DIR FINAL_TREE]...
# Fetch one pinned commit beside DESTINATION, detached when BRANCH is empty,
# replay each series in order, publish it, and verify the result. An existing
# destination is verified and reused.
materialize_pinned()
{
	label=$1
	destination=$2
	verifier=$3
	repository=$4
	commit=$5
	upstream_tree=$6
	branch=$7
	shift 7
	if [ -e "$destination" ] || [ -L "$destination" ]; then
		"$verifier" --android-root "$ROOT_DIR/android/lineage-24" \
			--aosp-source "$AOSP_SOURCE"
		printf '%s\n' "reusing pinned $label checkout: $destination"
		return
	fi

	parent=$(dirname -- "$destination")
	mkdir -p -- "$parent"
	STAGING=$(mktemp -d "$parent/.$(basename -- "$destination").prepare.XXXXXX")
	pinned_git init --quiet
	pinned_git remote add origin "$repository"
	pinned_git fetch --no-tags --depth=1 origin "$commit"
	if [ -n "$branch" ]; then
		pinned_git switch --create "$branch" "$commit"
	else
		pinned_git switch --detach "$commit"
	fi
	actual_tree=$(pinned_git rev-parse HEAD^{tree})
	[ "$actual_tree" = "$upstream_tree" ] ||
		fail "fetched $label tree is $actual_tree, expected $upstream_tree"

	while [ "$#" -ge 2 ]; do
		python3 -B "$ROOT_DIR/scripts/patch_series.py" apply \
			--repo "$STAGING" --series-dir "$ROOT_DIR/$1" \
			--expect-tree "$2" >/dev/null ||
			fail "the $label series $1 does not replay to $2"
		shift 2
	done
	mv -- "$STAGING" "$destination"
	STAGING=
	"$verifier" --android-root "$ROOT_DIR/android/lineage-24" \
		--aosp-source "$AOSP_SOURCE"
}

while [ "$#" -gt 0 ]; do
	case "$1" in
	--aosp-source)
		[ "$#" -ge 2 ] || fail "--aosp-source requires a path"
		AOSP_SOURCE=$2
		shift 2
		;;
	--jobs)
		[ "$#" -ge 2 ] || fail "--jobs requires a value"
		JOBS=$2
		shift 2
		;;
	-h|--help)
		usage
		exit 0
		;;
	*) fail "unknown option: $1" ;;
	esac
done

[ -n "$AOSP_SOURCE" ] || fail "--aosp-source is required"
absolute_path "AOSP source" "$AOSP_SOURCE"
[ -d "$AOSP_SOURCE" ] || fail "AOSP source does not exist: $AOSP_SOURCE"

[ "$(uname -s)" = Linux ] || fail "builder host must be Linux"
[ "$(uname -m)" = x86_64 ] || fail "builder host must be x86_64"

case "$JOBS" in
'') JOBS=$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '%s\n' 1) ;;
*[!0-9]*|0) fail "--jobs must be a positive integer" ;;
esac

[ -f "$AOSP_METADATA" ] || fail "missing AOSP metadata: $AOSP_METADATA"
[ -f "$MESA_VENUS_METADATA" ] ||
	fail "missing Mesa Venus metadata: $MESA_VENUS_METADATA"
[ -x "$MESA_VENUS_VERIFIER" ] ||
	fail "missing Mesa Venus source verifier: $MESA_VENUS_VERIFIER"
# shellcheck disable=SC1090
. "$AOSP_METADATA"
# shellcheck disable=SC1090
. "$MESA_VENUS_METADATA"

"$MESA_VENUS_VERIFIER" --android-root "$ROOT_DIR/android/lineage-24"

command -v repo >/dev/null 2>&1 || fail "repo is not available on PATH"
command -v git >/dev/null 2>&1 || fail "git is not available on PATH"
git lfs version >/dev/null 2>&1 || fail "git-lfs is not available on PATH"
[ -d "$AOSP_SOURCE/.repo" ] || fail "AOSP source is not a Repo workspace"

dirty_projects=$(dirty_repo_projects "$AOSP_SOURCE")
if [ -n "$dirty_projects" ]; then
	fail "AOSP Repo workspace has dirty projects: $dirty_projects"
fi

(
	CDPATH= cd -- "$AOSP_SOURCE"
	repo init -u "$LINEAGE24_MANIFEST_REPOSITORY" \
		-b "$LINEAGE24_MANIFEST_COMMIT" --manifest-depth=1 \
		--git-lfs --partial-clone --clone-filter=blob:none \
		--repo-rev=stable --no-repo-verify --no-clone-bundle
	python3 -B "$ROOT_DIR/android/lineage-24/tools/render-pin-manifest.py" \
		--base-manifest "$ROOT_DIR/android/lineage-24/metadata/base-manifest.xml" \
		--output .repo/local_manifests/pin.xml
	repo sync -c --detach --depth=1 -j "$JOBS"
	# Repo fetches the Git LFS objects, but a checkout writes their pointer
	# files unless the project has the LFS filters. Install them per project
	# instead of in the builder's global Git configuration, and replace the
	# pointers with the objects.
	repo forall -j "$JOBS" -c \
		'[ ! -f .lfsconfig ] || { git lfs install --local >/dev/null && git lfs checkout >/dev/null; }'
)

materialize_pinned "Mesa Venus" "$AOSP_SOURCE/$MESA_VENUS_DESTINATION" \
	"$MESA_VENUS_VERIFIER" "$MESA_VENUS_UPSTREAM_REPOSITORY" \
	"$MESA_VENUS_UPSTREAM_COMMIT" "$MESA_VENUS_UPSTREAM_TREE" \
	"$MESA_VENUS_PATCH_BRANCH" \
	"$MESA_VENUS_GUEST_SERIES" "$MESA_VENUS_GUEST_TREE" \
	android/lineage-24/third_party/mesa-venus/series "$MESA_VENUS_FINAL_TREE"

"$SCRIPT_DIR/preflight.sh" \
	--aosp-source "$AOSP_SOURCE" \
	--source-only
