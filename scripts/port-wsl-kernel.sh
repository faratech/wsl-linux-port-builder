#!/usr/bin/env bash
set -euo pipefail

LINUX_STABLE_REPO="${LINUX_STABLE_REPO:-https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git}"
MSFT_WSL_REPO="${MSFT_WSL_REPO:-https://github.com/microsoft/WSL2-Linux-Kernel.git}"
KERNEL_ORG_RELEASES="${KERNEL_ORG_RELEASES:-https://www.kernel.org/releases.json}"
MSFT_RELEASES_API="${MSFT_RELEASES_API:-https://api.github.com/repos/microsoft/WSL2-Linux-Kernel/releases}"

MODE="source"
LINUX_TRACK="stable"
LINUX_TAG=""
WSL_TAG=""
ARCH_INPUT="arm64"
OUTPUT_DIR="$PWD/out"
WORK_DIR=""
KEEP_WORK=0
JOBS="${JOBS:-$(nproc)}"
FORCE=0
SOURCE_TARBALL_ARTIFACT=""
PATCH_ARTIFACT=""

BUILD_ARCH=""
ARTIFACT_ARCH=""
IMAGE_TARGET=""
IMAGE_PATH=""
KCONFIG_LINK=""
KCONFIG_REAL=""
CROSS_COMPILE_ARG=()

info() { printf '[INFO] %s\n' "$*" >&2; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: scripts/port-wsl-kernel.sh [options]

Options:
  --mode resolve|source|build
  --linux-track stable|mainline
  --linux-tag vX.Y[.Z]
  --wsl-tag linux-msft-wsl-X.Y.Z.N
  --arch arm64|aarch64|x64|x86_64|amd64
  --output-dir DIR
  --work-dir DIR
  --jobs N
  --keep-work
  --force
  -h, --help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode) MODE="${2:?missing mode}"; shift ;;
        --linux-track) LINUX_TRACK="${2:?missing Linux track}"; shift ;;
        --linux-tag) LINUX_TAG="${2:?missing Linux tag}"; shift ;;
        --wsl-tag) WSL_TAG="${2:?missing WSL tag}"; shift ;;
        --arch) ARCH_INPUT="${2:?missing architecture}"; shift ;;
        --output-dir) OUTPUT_DIR="${2:?missing output directory}"; shift ;;
        --work-dir) WORK_DIR="${2:?missing work directory}"; shift ;;
        --jobs) JOBS="${2:?missing job count}"; shift ;;
        --keep-work) KEEP_WORK=1 ;;
        --force) FORCE=1 ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
    shift
done

require_commands() {
    local missing=()
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    [[ ${#missing[@]} -eq 0 ]] || die "Missing required command(s): ${missing[*]}"
}

tag_version() {
    printf '%s\n' "$1" | sed -E 's/^v//; s/^linux-msft-wsl-//'
}

wsl_base_linux_tag() {
    local version="$1"
    printf 'v%s\n' "${version%.*}"
}

latest_linux_version() {
    if [[ -n "$LINUX_TAG" ]]; then
        tag_version "$LINUX_TAG"
        return
    fi

    curl -fsSL "$KERNEL_ORG_RELEASES" \
        | jq -er --arg track "$LINUX_TRACK" \
            'first(.releases[] | select(.moniker == $track and (.iseol == false)) | .version)'
}

latest_wsl_version() {
    if [[ -n "$WSL_TAG" ]]; then
        tag_version "$WSL_TAG"
        return
    fi

    curl -fsSL "${MSFT_RELEASES_API}?per_page=1" \
        | jq -er '.[0].tag_name | sub("^linux-msft-wsl-"; "")'
}

normalize_arch() {
    case "$1" in
        aarch64|arm64)
            BUILD_ARCH="arm64"
            ARTIFACT_ARCH="arm64"
            IMAGE_TARGET="Image"
            IMAGE_PATH="arch/arm64/boot/Image"
            KCONFIG_LINK="Microsoft/config-wsl-arm64"
            KCONFIG_REAL="arch/arm64/configs/config-wsl-arm64"
            if [[ "$(uname -m)" != "aarch64" ]]; then
                CROSS_COMPILE_ARG=("CROSS_COMPILE=aarch64-linux-gnu-")
            fi
            ;;
        x86_64|amd64|x64|x86)
            BUILD_ARCH="x86"
            ARTIFACT_ARCH="x64"
            IMAGE_TARGET="bzImage"
            IMAGE_PATH="arch/x86/boot/bzImage"
            KCONFIG_LINK="Microsoft/config-wsl"
            KCONFIG_REAL="arch/x86/configs/config-wsl"
            ;;
        *)
            die "Unsupported architecture '$1'. Use arm64/aarch64 or x64/x86_64/amd64."
            ;;
    esac
}

write_metadata() {
    local path="$1"
    local commit="${2:-}"
    local kernel_release="${3:-}"
    local kernel_artifact="${4:-}"
    local modules_artifact="${5:-}"

    jq -n \
        --arg generated_at "$(date -Iseconds)" \
        --arg mode "$MODE" \
        --arg linux_track "$LINUX_TRACK" \
        --arg linux_version "$TARGET_LINUX_VERSION" \
        --arg linux_tag "$TARGET_LINUX_TAG" \
        --arg linux_repo "$LINUX_STABLE_REPO" \
        --arg wsl_version "$TARGET_WSL_VERSION" \
        --arg wsl_tag "$TARGET_WSL_TAG" \
        --arg wsl_base_linux_tag "$TARGET_WSL_BASE_LINUX_TAG" \
        --arg wsl_repo "$MSFT_WSL_REPO" \
        --arg host_arch "$(uname -m)" \
        --arg build_arch "$BUILD_ARCH" \
        --arg artifact_arch "$ARTIFACT_ARCH" \
        --arg image_target "$IMAGE_TARGET" \
        --arg image_path "$IMAGE_PATH" \
        --arg port_name "$PORT_NAME" \
        --arg port_tag "$PORT_TAG" \
        --arg source_branch "$SOURCE_BRANCH" \
        --arg commit "$commit" \
        --arg source_tarball "$SOURCE_TARBALL_ARTIFACT" \
        --arg patch "$PATCH_ARTIFACT" \
        --arg kernel_release "$kernel_release" \
        --arg kernel_artifact "$kernel_artifact" \
        --arg modules_artifact "$modules_artifact" \
        '{
          schema: 1,
          generated_at: $generated_at,
          mode: $mode,
          linux: {
            track: $linux_track,
            version: $linux_version,
            tag: $linux_tag,
            repository: $linux_repo
          },
          microsoft_wsl: {
            version: $wsl_version,
            tag: $wsl_tag,
            base_linux_tag: $wsl_base_linux_tag,
            repository: $wsl_repo
          },
          arch: {
            host_uname: $host_arch,
            build_arch: $build_arch,
            artifact_arch: $artifact_arch,
            image_target: $image_target,
            image_path: $image_path
          },
          port: {
            name: $port_name,
            tag: $port_tag,
            source_branch: $source_branch,
            commit: $commit
          },
          artifacts: {
            source_tarball: $source_tarball,
            patch: $patch,
            kernel_release: $kernel_release,
            kernel: $kernel_artifact,
            modules_vhdx: $modules_artifact
          }
        }' > "$path"
}

write_release_notes() {
    local path="$1"
    cat > "$path" <<EOF
# $PORT_TAG

- Linux base: \`$TARGET_LINUX_TAG\` ($LINUX_TRACK)
- Microsoft WSL base: \`$TARGET_WSL_TAG\`
- Microsoft WSL merge base: \`$TARGET_WSL_BASE_LINUX_TAG\`
- Architecture: \`$ARTIFACT_ARCH\` (make ARCH=\`$BUILD_ARCH\`)

Generated by \`scripts/port-wsl-kernel.sh\`.
EOF
}

ensure_dxg_entries() {
    local work="$1"
    python3 - "$work" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])

kconfig = root / "drivers/hv/Kconfig"
if kconfig.exists():
    text = kconfig.read_text()
    line = 'source "drivers/hv/dxgkrnl/Kconfig"'
    text = text.replace("config HYPERV_TIMER\n\tdef_bool HYPERV && X86",
                        "config HYPERV_TIMER\n\tdef_bool HYPERV")
    text = text.replace("\n" + line + "\n", "\n")
    marker = "\nendmenu"
    pos = text.rfind(marker)
    if pos != -1:
        text = text[:pos] + "\n" + line + "\n" + text[pos:]
    else:
        text = text.rstrip() + "\n" + line + "\n"
    text = re.sub(r"\n{3,}" + re.escape(line), "\n\n" + line, text)
    kconfig.write_text(text)

makefile = root / "drivers/hv/Makefile"
if makefile.exists():
    text = makefile.read_text()
    dxg_line = "obj-$(CONFIG_DXGKRNL)\t\t+= dxgkrnl/"
    text = re.sub(r"^obj-\$\(CONFIG_DXGKRNL\).*dxgkrnl/\n?", "", text, flags=re.M)
    marker = "CFLAGS_hv_trace.o"
    text = re.sub(r"\n{2,}(?=" + re.escape(marker) + ")", "\n", text)
    if marker in text:
        text = text.replace(marker, dxg_line + "\n\n" + marker, 1)
    else:
        text = text.rstrip() + "\n" + dxg_line + "\n"
    text = text.replace(dxg_line + "\n\n\n", dxg_line + "\n\n")
    makefile.write_text(text)
PY
}

resolve_known_conflicts() {
    local work="$1"
    mapfile -t conflicts < <(git -C "$work" diff --name-only --diff-filter=U | sort)
    [[ ${#conflicts[@]} -gt 0 ]] || return 0

    for file in "${conflicts[@]}"; do
        case "$file" in
            Makefile|arch/x86/kernel/cpu/mshyperv.c|drivers/hv/Kconfig|drivers/hv/Makefile) ;;
            *)
                git -C "$work" status --short >&2
                die "Unknown WSL/Linux merge conflict in $file"
                ;;
        esac
    done

    warn "Resolving known WSL port conflicts: ${conflicts[*]}"
    git -C "$work" checkout --ours -- "${conflicts[@]}"
    ensure_dxg_entries "$work"
    git -C "$work" add "${conflicts[@]}"
}

apply_known_compatibility_patches() {
    local work="$1"
    local dxgsync="$work/drivers/hv/dxgkrnl/dxgsyncfile.c"
    local mshyperv="$work/arch/x86/kernel/cpu/mshyperv.c"

    ensure_dxg_entries "$work"

    if [[ -f "$dxgsync" ]] && grep -q '__dma_fence_is_later(syncpoint->fence_value' "$dxgsync"; then
        info "Applying known dxgkrnl dma_fence compatibility fix..."
        perl -i -0pe 's/__dma_fence_is_later\(syncpoint->fence_value,\s*fence->seqno,\s*fence->ops\)/__dma_fence_is_later(fence, syncpoint->fence_value, fence->seqno)/' "$dxgsync"
    fi
    if [[ -f "$dxgsync" ]]; then
        perl -i -0pe 's/if \(syncobj\)[ \t]+\n/if (syncobj)\n/g' "$dxgsync"
    fi

    if [[ -f "$mshyperv" ]] && ! grep -q 'Host builds earlier than 22621' "$mshyperv"; then
        info "Preserving Microsoft Hyper-V invariant TSC workaround..."
        python3 - "$mshyperv" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
text = text.replace(
    "static void __init ms_hyperv_init_platform(void)\n"
    "{\n"
    "\tint hv_max_functions_eax, eax;\n",
    "static void __init ms_hyperv_init_platform(void)\n"
    "{\n"
    "\tint hv_max_functions_eax, eax;\n"
    "\tunion hv_hypervisor_version_info version;\n"
    "\tunsigned int build = 0;\n",
)
text = text.replace(
    "\tpr_debug(\"Hyper-V: max %u virtual processors, %u logical processors\\n\",\n"
    "\t\t ms_hyperv.max_vp_index, ms_hyperv.max_lp_index);\n\n"
    "\thv_identify_partition_type();\n",
    "\tpr_debug(\"Hyper-V: max %u virtual processors, %u logical processors\\n\",\n"
    "\t\t ms_hyperv.max_vp_index, ms_hyperv.max_lp_index);\n\n"
    "\t/*\n"
    "\t * Host builds earlier than 22621 (Win 11 22H2) have a bug in the\n"
    "\t * invariant TSC feature that may result in the guest seeing a \"slow\"\n"
    "\t * TSC after host hibernation. This causes problems with synthetic\n"
    "\t * timer interrupts. In such a case, avoid the bug by assuming the\n"
    "\t * feature is not present.\n"
    "\t */\n"
    "\tif (!hv_get_hypervisor_version(&version))\n"
    "\t\tbuild = version.build_number;\n"
    "\tif (build < 22621)\n"
    "\t\tms_hyperv.features &= ~HV_ACCESS_TSC_INVARIANT;\n\n"
    "\thv_identify_partition_type();\n",
)
path.write_text(text)
PY
    fi
}

prepare_config() {
    local work="$1"
    cp "$work/$KCONFIG_LINK" "$work/.config"
    make -C "$work" ARCH="$BUILD_ARCH" "${CROSS_COMPILE_ARG[@]}" olddefconfig
    cp "$work/.config" "$work/$KCONFIG_REAL"
    chmod 0644 "$work/$KCONFIG_REAL"
    ln -sfn "../$KCONFIG_REAL" "$work/$KCONFIG_LINK"
}

build_kernel_and_modules() {
    local work="$1"
    local out="$2"
    local log="$out/build.log"

    info "Building $IMAGE_TARGET and modules with $JOBS jobs..."
    make -C "$work" ARCH="$BUILD_ARCH" "${CROSS_COMPILE_ARG[@]}" -j"$JOBS" "$IMAGE_TARGET" modules 2>&1 | tee "$log"

    KERNEL_RELEASE="$(make -s -C "$work" ARCH="$BUILD_ARCH" "${CROSS_COMPILE_ARG[@]}" kernelrelease)"
    [[ -n "$KERNEL_RELEASE" ]] || die "Could not determine kernel release"

    local stage="$out/modules-staging"
    info "Installing modules to staging..."
    make -C "$work" ARCH="$BUILD_ARCH" "${CROSS_COMPILE_ARG[@]}" INSTALL_MOD_PATH="$stage" modules_install 2>&1 | tee -a "$log"

    local module_root="$stage/lib/modules/$KERNEL_RELEASE"
    [[ -d "$module_root" ]] || die "Missing staged modules at $module_root"

    local modules_img="$out/modules.img"
    local modules_size
    modules_size="$(du -bs "$module_root" | awk '{print $1}')"
    modules_size=$((modules_size + 256 * 1024 * 1024))

    KERNEL_ARTIFACT="kernel-$KERNEL_RELEASE-$ARTIFACT_ARCH"
    MODULES_ARTIFACT="modules-$KERNEL_RELEASE-$ARTIFACT_ARCH.vhdx"

    cp "$work/$IMAGE_PATH" "$out/$KERNEL_ARTIFACT"
    truncate -s "$modules_size" "$modules_img"
    mkfs.ext4 -F -d "$module_root" "$modules_img" >/dev/null
    qemu-img convert -O vhdx "$modules_img" "$out/$MODULES_ARTIFACT"
    qemu-img check "$out/$MODULES_ARTIFACT"
    rm -rf "$stage" "$modules_img"
}

require_commands git curl jq sed awk sort python3 perl make tar

case "$MODE" in
    resolve|source|build) ;;
    *) die "Unsupported mode: $MODE" ;;
esac
case "$LINUX_TRACK" in
    stable|mainline) ;;
    *) die "Unsupported Linux track: $LINUX_TRACK" ;;
esac
if [[ "$MODE" == "build" ]]; then
    require_commands qemu-img mkfs.ext4 truncate
fi

normalize_arch "$ARCH_INPUT"
TARGET_LINUX_VERSION="$(latest_linux_version)"
TARGET_WSL_VERSION="$(latest_wsl_version)"
TARGET_LINUX_TAG="${LINUX_TAG:-v$TARGET_LINUX_VERSION}"
TARGET_WSL_TAG="${WSL_TAG:-linux-msft-wsl-$TARGET_WSL_VERSION}"
TARGET_WSL_BASE_LINUX_TAG="$(wsl_base_linux_tag "$TARGET_WSL_VERSION")"
PORT_NAME="linux-$TARGET_LINUX_VERSION-msft-wsl-$TARGET_WSL_VERSION-$ARTIFACT_ARCH"
PORT_TAG="port/$PORT_NAME"
SOURCE_BRANCH="generated/$PORT_NAME"
KERNEL_RELEASE=""
KERNEL_ARTIFACT=""
MODULES_ARTIFACT=""

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

if [[ "$MODE" == "resolve" ]]; then
    write_metadata "$OUTPUT_DIR/metadata.json" "" "" "" ""
    write_release_notes "$OUTPUT_DIR/release-notes.md"
    jq . "$OUTPUT_DIR/metadata.json"
    exit 0
fi

if [[ -z "$WORK_DIR" ]]; then
    WORK_DIR="$(mktemp -d /tmp/wsl-linux-port.XXXXXX)"
else
    mkdir -p "$WORK_DIR"
    WORK_DIR="$(cd "$WORK_DIR" && pwd)"
fi

REPO="$WORK_DIR/repo"
WORKTREE="$WORK_DIR/source"
CLEANUP_OK=0
cleanup() {
    local rc=$?
    if [[ "$KEEP_WORK" -eq 0 && "$CLEANUP_OK" -eq 1 ]]; then
        rm -rf "$WORK_DIR"
    elif [[ "$KEEP_WORK" -eq 0 && "$rc" -ne 0 ]]; then
        warn "Work directory retained for failed run: $WORK_DIR"
    else
        info "Work directory retained: $WORK_DIR"
    fi
}
trap cleanup EXIT

info "Initializing source repo in $REPO..."
git init "$REPO" >/dev/null
git -C "$REPO" remote add linux "$LINUX_STABLE_REPO"
git -C "$REPO" remote add microsoft "$MSFT_WSL_REPO"
git -C "$REPO" config user.name "wsl-linux-port-builder"
git -C "$REPO" config user.email "actions@users.noreply.github.com"

info "Fetching $TARGET_LINUX_TAG, $TARGET_WSL_BASE_LINUX_TAG, and $TARGET_WSL_TAG..."
git -C "$REPO" fetch --no-tags --depth=1 linux "+refs/tags/$TARGET_LINUX_TAG:refs/tags/$TARGET_LINUX_TAG"
git -C "$REPO" fetch --no-tags --depth=1 linux "+refs/tags/$TARGET_WSL_BASE_LINUX_TAG:refs/tags/$TARGET_WSL_BASE_LINUX_TAG"
git -C "$REPO" fetch --no-tags --depth=1 microsoft "+refs/tags/$TARGET_WSL_TAG:refs/tags/$TARGET_WSL_TAG"

TARGET_LINUX_COMMIT="$(git -C "$REPO" rev-parse "$TARGET_LINUX_TAG^{commit}")"
TARGET_WSL_BASE_LINUX_COMMIT="$(git -C "$REPO" rev-parse "$TARGET_WSL_BASE_LINUX_TAG^{commit}")"
TARGET_WSL_COMMIT="$(git -C "$REPO" rev-parse "$TARGET_WSL_TAG^{commit}")"

info "Creating Linux base worktree..."
git -C "$REPO" worktree add --detach "$WORKTREE" "$TARGET_LINUX_COMMIT" >/dev/null

info "Merging Microsoft WSL delta..."
set +e
git -C "$WORKTREE" merge-recursive "$TARGET_WSL_BASE_LINUX_COMMIT" -- HEAD "$TARGET_WSL_COMMIT"
merge_rc=$?
set -e
if [[ "$merge_rc" -ne 0 ]]; then
    resolve_known_conflicts "$WORKTREE"
fi
if [[ -n "$(git -C "$WORKTREE" diff --name-only --diff-filter=U)" ]]; then
    git -C "$WORKTREE" status --short >&2
    die "Unresolved conflicts remain"
fi

apply_known_compatibility_patches "$WORKTREE"
prepare_config "$WORKTREE"

write_metadata "$WORKTREE/Microsoft/custom-wsl-port.json" "" "" "" ""
git -C "$WORKTREE" add -A
TREE_ID="$(git -C "$WORKTREE" write-tree)"
COMMIT_MSG="$(cat <<EOF
Port Linux $TARGET_LINUX_VERSION with Microsoft WSL $TARGET_WSL_VERSION

Linux base: $TARGET_LINUX_TAG
Microsoft WSL base: $TARGET_WSL_TAG
Microsoft WSL merge base: $TARGET_WSL_BASE_LINUX_TAG
Architecture: $ARTIFACT_ARCH
Generated-by: wsl-linux-port-builder
EOF
)"
COMBINED_COMMIT="$(printf '%s\n' "$COMMIT_MSG" | git -C "$WORKTREE" commit-tree "$TREE_ID" -p "$TARGET_LINUX_COMMIT" -p "$TARGET_WSL_COMMIT")"
git -C "$REPO" update-ref "refs/heads/$SOURCE_BRANCH" "$COMBINED_COMMIT"

info "Generated $SOURCE_BRANCH at $COMBINED_COMMIT"

SOURCE_TARBALL_ARTIFACT="source-$PORT_NAME.tar.gz"
PATCH_ARTIFACT="patch-$PORT_NAME.patch"
info "Writing source patch and tarball..."
git -C "$REPO" diff --binary "$TARGET_LINUX_COMMIT" "$COMBINED_COMMIT" > "$OUTPUT_DIR/$PATCH_ARTIFACT"
tar --sort=name --mtime='UTC 1970-01-01' --owner=0 --group=0 --numeric-owner \
    --exclude=.git -C "$WORKTREE" -czf "$OUTPUT_DIR/$SOURCE_TARBALL_ARTIFACT" .

if [[ "$MODE" == "build" ]]; then
    build_kernel_and_modules "$WORKTREE" "$OUTPUT_DIR"
fi

write_metadata "$OUTPUT_DIR/metadata.json" "$COMBINED_COMMIT" "$KERNEL_RELEASE" "$KERNEL_ARTIFACT" "$MODULES_ARTIFACT"
write_release_notes "$OUTPUT_DIR/release-notes.md"

CLEANUP_OK=1
info "Output written to $OUTPUT_DIR"
