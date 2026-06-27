#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="${CUSTOM_WSL_REPO:-/root/wsl-kernel-port-7.1.1/linux}"
LINUX_UPSTREAM_REMOTE="${LINUX_UPSTREAM_REMOTE:-stable}"
LINUX_FORK_REMOTE="${LINUX_FORK_REMOTE:-linux-fork}"
MSFT_REMOTE="${MSFT_REMOTE:-microsoft}"
WSL_FORK_REMOTE="${WSL_FORK_REMOTE:-fork}"
BUILDER_REPO="${CUSTOM_WSL_BUILDER_REPO:-faratech/wsl-linux-port-builder}"
BUILDER_API="${CUSTOM_WSL_BUILDER_API:-https://api.github.com/repos/$BUILDER_REPO}"
KERNEL_ORG_RELEASES="${KERNEL_ORG_RELEASES:-https://www.kernel.org/releases.json}"
MSFT_RELEASES_API="${MSFT_RELEASES_API:-https://api.github.com/repos/microsoft/WSL2-Linux-Kernel/releases}"
WIN_PROFILE="$(wslpath "$(cmd.exe /C 'echo %USERPROFILE%' < /dev/null 2>/dev/null | tr -d '\r')")"
KERNEL_DEST="${CUSTOM_WSL_KERNEL_DEST:-$WIN_PROFILE/wsl-kernel}"
WSLCONFIG="${CUSTOM_WSL_CONFIG:-$WIN_PROFILE/.wslconfig}"
METADATA="${CUSTOM_WSL_METADATA:-$KERNEL_DEST/custom-wsl-kernel.json}"
JOBS="${JOBS:-$(nproc)}"
# Build scratch must live on disk. /tmp is frequently a small RAM-backed tmpfs
# (e.g. WSL defaults to one sized at ~half of RAM), far too small for a full
# kernel build + module staging + ext4 image + VHDX, and filling it can wedge
# the whole system. Default to /var/tmp (disk on a normal WSL distro); override
# with CUSTOM_WSL_WORKDIR. CUSTOM_WSL_MIN_FREE_GIB tunes the preflight check.
WORKDIR_BASE="${CUSTOM_WSL_WORKDIR:-/var/tmp}"
MIN_FREE_GIB="${CUSTOM_WSL_MIN_FREE_GIB:-15}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

MODE="update"
YES=0
FORCE=0
PUSH=0
USE_FORK_CACHE=0
INSTALL=1
BUILD=1
SOURCE_MODE="auto"
LINUX_TAG_OVERRIDE=""
WSL_TAG_OVERRIDE=""
ARCH_OVERRIDE=""
HOST_UNAME_ARCH="$(uname -m)"
BUILD_ARCH=""
ARTIFACT_ARCH=""
CROSS_COMPILE_ARG=()
GH_RELEASE_JSON=""
GH_RELEASE_AVAILABLE=0
GH_BINARY_AVAILABLE=0
GH_SOURCE_AVAILABLE=0
GH_METADATA_URL=""
GH_KERNEL_URL=""
GH_KERNEL_NAME=""
GH_MODULES_URL=""
GH_MODULES_NAME=""
GH_SOURCE_URL=""
GH_SOURCE_NAME=""
GH_PATCH_URL=""
GH_PATCH_NAME=""

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: update-custom-wsl-kernel.sh [options]

Checks or rebuilds the custom WSL kernel from two independent inputs:
  1. latest kernel.org stable Linux tag
  2. latest Microsoft WSL kernel release tag

By default, update installs prefer releases from faratech/wsl-linux-port-builder
and fall back to local direct upstream builds from kernel.org/Microsoft sources.

Options:
  --check             Print only an update notice when either input is newer.
  --status            Print current and latest Linux/WSL base versions.
  --dry-run           Print the planned action without fetching/building.
  -y, --yes           Do not ask before a full rebuild/install.
  --force             Rebuild even when no newer input is detected.
  --linux-tag TAG     Override the target Linux tag, e.g. v7.1.2.
  --wsl-tag TAG       Override the target WSL tag, e.g. linux-msft-wsl-6.18.35.3.
  --arch ARCH         Override build arch: arm64/aarch64 or x64/x86_64/amd64.
  --source MODE       auto, github, or local. Default: auto.
  --skip-build        Regenerate and push the combined branch only.
  --no-install        Build but do not copy artifacts or update .wslconfig.
  --use-fork-cache    Prefer old fork remotes as optional fetch caches.
  --push-branch       Push the generated local branch to the WSL fork remote.
  --no-push           Compatibility alias; local branch pushes are off by default.
  -h, --help          Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check) MODE="check" ;;
        --status) MODE="status" ;;
        --dry-run) MODE="dry-run" ;;
        -y|--yes) YES=1 ;;
        --force) FORCE=1 ;;
        --linux-tag) LINUX_TAG_OVERRIDE="${2:?missing Linux tag}"; shift ;;
        --wsl-tag) WSL_TAG_OVERRIDE="${2:?missing WSL tag}"; shift ;;
        --arch) ARCH_OVERRIDE="${2:?missing arch}"; shift ;;
        --source) SOURCE_MODE="${2:?missing source mode}"; shift ;;
        --skip-build) BUILD=0; INSTALL=0 ;;
        --no-install) INSTALL=0 ;;
        --use-fork-cache) USE_FORK_CACHE=1 ;;
        --push-branch) PUSH=1 ;;
        --no-push) PUSH=0 ;;
        -h|--help) usage; exit 0 ;;
        *) error "Unknown option: $1" ;;
    esac
    shift
done

require_commands() {
    local missing=()
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing required command(s): ${missing[*]}"
    fi
}

require_free_space() {
    local dir="$1"
    local need_gib="$2"
    local avail_kib avail_gib
    avail_kib="$(df -Pk "$dir" 2>/dev/null | awk 'NR==2 {print $4}')"
    [[ -n "$avail_kib" ]] || return 0
    avail_gib=$((avail_kib / 1024 / 1024))
    if [[ "$avail_gib" -lt "$need_gib" ]]; then
        error "Insufficient build space in $dir: ${avail_gib} GiB free, need ~${need_gib} GiB. Point CUSTOM_WSL_WORKDIR at a larger disk-backed directory (current base: $WORKDIR_BASE; note /tmp is often a small tmpfs)."
    fi
    info "Build scratch: $dir (${avail_gib} GiB free)"
}

kernel_base_version() {
    printf '%s\n' "$1" | sed -E 's/^[^0-9]*//; s/[^0-9.].*$//; s/[.]+$//'
}

version_gt() {
    [[ "$1" != "$2" ]] && [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" == "$1" ]]
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
            if [[ "$HOST_UNAME_ARCH" != "aarch64" ]]; then
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
            if [[ "$HOST_UNAME_ARCH" != "x86_64" && "$HOST_UNAME_ARCH" != "amd64" ]]; then
                CROSS_COMPILE_ARG=("CROSS_COMPILE=x86_64-linux-gnu-")
            fi
            ;;
        *)
            error "Unsupported architecture '$1'. Use arm64/aarch64 or x64/x86_64/amd64."
            ;;
    esac
}

join_update_parts() {
    local joined=""
    local part
    for part in "$@"; do
        if [[ -n "$joined" ]]; then
            joined+="; "
        fi
        joined+="$part"
    done
    printf '%s\n' "$joined"
}

tag_version() {
    printf '%s\n' "$1" | sed -E 's/^v//; s/^linux-msft-wsl-//'
}

wsl_base_linux_tag() {
    local version="$1"
    printf 'v%s\n' "${version%.*}"
}

metadata_get() {
    local expr="$1"
    [[ -f "$METADATA" ]] || return 0
    jq -r "$expr // empty" "$METADATA" 2>/dev/null || true
}

latest_linux_stable_version() {
    if [[ -n "$LINUX_TAG_OVERRIDE" ]]; then
        tag_version "$LINUX_TAG_OVERRIDE"
        return
    fi
    curl -sf --max-time 10 "$KERNEL_ORG_RELEASES" \
        | jq -er 'first(.releases[] | select(.moniker == "stable" and (.iseol == false)) | .version)'
}

latest_wsl_version() {
    if [[ -n "$WSL_TAG_OVERRIDE" ]]; then
        tag_version "$WSL_TAG_OVERRIDE"
        return
    fi
    curl -sf --max-time 10 "${MSFT_RELEASES_API}?per_page=1" \
        | jq -er '.[0].tag_name | sub("^linux-msft-wsl-"; "")'
}

remote_exists() {
    git -C "$REPO_DIR" remote get-url "$1" >/dev/null 2>&1
}

fetch_tag() {
    local remote="$1"
    local tag="$2"
    info "Fetching $tag from $remote..."
    git -C "$REPO_DIR" fetch --no-tags "$remote" "+refs/tags/$tag:refs/tags/$tag"
}

fetch_tag_prefer() {
    local primary="$1"
    local fallback="$2"
    local tag="$3"

    if remote_exists "$primary" && git -C "$REPO_DIR" ls-remote --exit-code --tags "$primary" "$tag" >/dev/null 2>&1; then
        fetch_tag "$primary" "$tag"
        return
    fi

    if [[ -n "$fallback" ]] && remote_exists "$fallback"; then
        warn "$primary does not have $tag yet; falling back to $fallback"
        fetch_tag "$fallback" "$tag"
        return
    fi

    error "Could not fetch $tag: neither $primary nor $fallback has it"
}

ensure_linux_fork_has_tag() {
    local tag="$1"
    [[ "$PUSH" -eq 1 ]] || return 0
    remote_exists "$LINUX_FORK_REMOTE" || return 0
    info "Ensuring Linux fork has $tag..."
    git -C "$REPO_DIR" push "$LINUX_FORK_REMOTE" "refs/tags/$tag:refs/tags/$tag" >/dev/null 2>&1 \
        || warn "Could not push $tag to $LINUX_FORK_REMOTE; continuing because kernel.org has the source tag."
}

download_url() {
    local url="$1"
    local dest="$2"
    curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 10 "$url" -o "$dest"
}

github_release_url() {
    local tag="$1"
    printf '%s/releases/tags/%s\n' "$BUILDER_API" "$tag"
}

asset_field() {
    local json="$1"
    local regex="$2"
    local field="$3"
    jq -r --arg regex "$regex" --arg field "$field" \
        'first(.assets[]? | select(.name | test($regex)) | .[$field]) // empty' "$json"
}

inspect_github_release() {
    local tag="$1"
    local tmp

    GH_RELEASE_JSON=""
    GH_RELEASE_AVAILABLE=0
    GH_BINARY_AVAILABLE=0
    GH_SOURCE_AVAILABLE=0
    GH_METADATA_URL=""
    GH_KERNEL_URL=""
    GH_KERNEL_NAME=""
    GH_MODULES_URL=""
    GH_MODULES_NAME=""
    GH_SOURCE_URL=""
    GH_SOURCE_NAME=""
    GH_PATCH_URL=""
    GH_PATCH_NAME=""

    tmp="$(mktemp /tmp/custom-wsl-release.XXXXXX.json)"
    if ! curl -fsSL --connect-timeout 10 "$(github_release_url "$tag")" -o "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        return 1
    fi

    GH_RELEASE_JSON="$tmp"
    GH_RELEASE_AVAILABLE=1
    GH_METADATA_URL="$(asset_field "$tmp" '^metadata[.]json$' browser_download_url)"
    GH_KERNEL_URL="$(asset_field "$tmp" '^kernel-' browser_download_url)"
    GH_KERNEL_NAME="$(asset_field "$tmp" '^kernel-' name)"
    GH_MODULES_URL="$(asset_field "$tmp" '^modules-.*[.]vhdx$' browser_download_url)"
    GH_MODULES_NAME="$(asset_field "$tmp" '^modules-.*[.]vhdx$' name)"
    GH_SOURCE_URL="$(asset_field "$tmp" '^source-.*[.]tar[.]gz$' browser_download_url)"
    GH_SOURCE_NAME="$(asset_field "$tmp" '^source-.*[.]tar[.]gz$' name)"
    GH_PATCH_URL="$(asset_field "$tmp" '^patch-.*[.]patch$' browser_download_url)"
    GH_PATCH_NAME="$(asset_field "$tmp" '^patch-.*[.]patch$' name)"

    [[ -n "$GH_METADATA_URL" && -n "$GH_KERNEL_URL" && -n "$GH_MODULES_URL" ]] && GH_BINARY_AVAILABLE=1
    [[ -n "$GH_METADATA_URL" && -n "$GH_SOURCE_URL" ]] && GH_SOURCE_AVAILABLE=1
    rm -f "$tmp"
    return 0
}

github_release_summary() {
    if [[ "$GH_RELEASE_AVAILABLE" -ne 1 ]]; then
        if [[ "$SOURCE_MODE" == "local" ]]; then
            printf 'not checked (--source local)'
        else
            printf 'missing'
        fi
    elif [[ "$GH_BINARY_AVAILABLE" -eq 1 ]]; then
        printf 'binary artifacts available'
    elif [[ "$GH_SOURCE_AVAILABLE" -eq 1 ]]; then
        printf 'source-only release available'
    else
        printf 'release exists but has no usable artifact set'
    fi
}

validate_release_metadata() {
    local metadata_path="$1"
    jq -e \
        --arg linux_version "$TARGET_LINUX_VERSION" \
        --arg linux_tag "$TARGET_LINUX_TAG" \
        --arg wsl_version "$TARGET_WSL_VERSION" \
        --arg wsl_tag "$TARGET_WSL_TAG" \
        --arg arch "$ARTIFACT_ARCH" \
        '.linux.version == $linux_version
         and .linux.tag == $linux_tag
         and .microsoft_wsl.version == $wsl_version
         and .microsoft_wsl.tag == $wsl_tag
         and .arch.artifact_arch == $arch' "$metadata_path" >/dev/null
}

release_metadata_value() {
    local metadata_path="$1"
    local expr="$2"
    jq -r "$expr // empty" "$metadata_path" 2>/dev/null || true
}

selected_update_path() {
    case "$SOURCE_MODE" in
        local)
            printf 'local'
            ;;
        github)
            [[ "$GH_RELEASE_AVAILABLE" -eq 1 ]] || error "Required GitHub release is missing: $RELEASE_TAG"
            if [[ "$GH_BINARY_AVAILABLE" -eq 1 ]]; then
                printf 'github-binary'
            elif [[ "$GH_SOURCE_AVAILABLE" -eq 1 ]]; then
                printf 'github-source'
            else
                error "GitHub release exists but has no usable artifact set: $RELEASE_TAG"
            fi
            ;;
        auto)
            if [[ "$GH_BINARY_AVAILABLE" -eq 1 ]]; then
                printf 'github-binary'
            elif [[ "$GH_SOURCE_AVAILABLE" -eq 1 ]]; then
                printf 'github-source'
            else
                printf 'local'
            fi
            ;;
        *)
            error "Unsupported source mode '$SOURCE_MODE'. Use auto, github, or local."
            ;;
    esac
}

update_wslconfig() {
    local kernel_win="$1"
    local modules_win="$2"

    python3 - "$WSLCONFIG" "$kernel_win" "$modules_win" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
kernel = sys.argv[2]
modules = sys.argv[3]

lines = path.read_text().splitlines() if path.exists() else []
out = []
in_wsl2 = False
saw_wsl2 = False
saw_kernel = False
saw_modules = False
inserted = False

def insert_missing():
    global inserted
    if in_wsl2 and not inserted:
        if not saw_kernel:
            out.append(f"kernel={kernel}")
        if not saw_modules:
            out.append(f"kernelModules={modules}")
        inserted = True

for line in lines:
    stripped = line.strip()
    if stripped.startswith("[") and stripped.endswith("]"):
        insert_missing()
        in_wsl2 = stripped.lower() == "[wsl2]"
        if in_wsl2:
            saw_wsl2 = True
        out.append(line)
        continue

    if in_wsl2 and line.startswith("kernel="):
        out.append(f"kernel={kernel}")
        saw_kernel = True
    elif in_wsl2 and line.startswith("kernelModules="):
        out.append(f"kernelModules={modules}")
        saw_modules = True
    else:
        out.append(line)

insert_missing()

if not saw_wsl2:
    if out and out[-1] != "":
        out.append("")
    out.extend(["[wsl2]", f"kernel={kernel}", f"kernelModules={modules}"])

path.write_text("\n".join(out) + "\n")
PY
}

write_metadata() {
    local path="$1"
    local linux_version="$2"
    local linux_tag="$3"
    local wsl_version="$4"
    local wsl_tag="$5"
    local base_tag="$6"
    local branch="$7"
    local commit="$8"
    local kernel_release="$9"
    local kernel_path="${10:-}"
    local modules_path="${11:-}"
    local linux_fork_url=""
    local wsl_fork_url=""
    local stable_url=""
    local microsoft_url=""

    linux_fork_url="$(git -C "$REPO_DIR" remote get-url "$LINUX_FORK_REMOTE" 2>/dev/null || true)"
    wsl_fork_url="$(git -C "$REPO_DIR" remote get-url "$WSL_FORK_REMOTE" 2>/dev/null || true)"
    stable_url="$(git -C "$REPO_DIR" remote get-url "$LINUX_UPSTREAM_REMOTE" 2>/dev/null || true)"
    microsoft_url="$(git -C "$REPO_DIR" remote get-url "$MSFT_REMOTE" 2>/dev/null || true)"

    mkdir -p "$(dirname "$path")"
    jq -n \
        --arg generated_at "$(date -Iseconds)" \
        --arg linux_version "$linux_version" \
        --arg linux_tag "$linux_tag" \
        --arg linux_upstream_remote "$LINUX_UPSTREAM_REMOTE" \
        --arg linux_upstream_url "$stable_url" \
        --arg linux_fork_remote "$LINUX_FORK_REMOTE" \
        --arg linux_fork_url "$linux_fork_url" \
        --arg wsl_version "$wsl_version" \
        --arg wsl_tag "$wsl_tag" \
        --arg wsl_base_linux_tag "$base_tag" \
        --arg wsl_upstream_remote "$MSFT_REMOTE" \
        --arg wsl_upstream_url "$microsoft_url" \
        --arg combined_branch "$branch" \
        --arg combined_commit "$commit" \
        --arg combined_remote "$WSL_FORK_REMOTE" \
        --arg combined_remote_url "$wsl_fork_url" \
        --arg kernel_release "$kernel_release" \
        --arg kernel_path "$kernel_path" \
        --arg modules_path "$modules_path" \
        --arg host_uname_arch "$HOST_UNAME_ARCH" \
        --arg build_arch "$BUILD_ARCH" \
        --arg artifact_arch "$ARTIFACT_ARCH" \
        '{
          schema: 1,
          generated_at: $generated_at,
          arch: {
            host_uname: $host_uname_arch,
            build_arch: $build_arch,
            artifact_arch: $artifact_arch
          },
          linux: {
            version: $linux_version,
            tag: $linux_tag,
            upstream_remote: $linux_upstream_remote,
            upstream_url: $linux_upstream_url,
            fork_remote: $linux_fork_remote,
            fork_url: $linux_fork_url
          },
          microsoft_wsl: {
            version: $wsl_version,
            tag: $wsl_tag,
            base_linux_tag: $wsl_base_linux_tag,
            upstream_remote: $wsl_upstream_remote,
            upstream_url: $wsl_upstream_url
          },
          combined: {
            branch: $combined_branch,
            commit: $combined_commit,
            remote: $combined_remote,
            remote_url: $combined_remote_url
          },
          artifacts: {
            kernel_release: $kernel_release,
            kernel_path: $kernel_path,
            modules_vhdx_path: $modules_path
          }
        }' > "$path"
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
    if line not in text:
        marker = "\nendmenu"
        pos = text.rfind(marker)
        if pos != -1:
            text = text[:pos] + "\n" + line + "\n" + text[pos:]
        else:
            text = text.rstrip() + "\n" + line + "\n"
    else:
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
                error "Unknown WSL/Linux merge conflict in $file. Leaving worktree for manual inspection."
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

require_config_commands() {
    require_commands make perl
    if [[ ${#CROSS_COMPILE_ARG[@]} -gt 0 ]]; then
        local prefix="${CROSS_COMPILE_ARG[0]#CROSS_COMPILE=}"
        require_commands "${prefix}gcc"
    fi
}

require_build_commands() {
    require_config_commands
    require_commands qemu-img mkfs.ext4 truncate
}

build_kernel_and_modules() {
    local work="$1"
    local tmp="$2"
    local log="$tmp/build.log"

    info "Building $IMAGE_TARGET and modules with $JOBS jobs..."
    make -C "$work" ARCH="$BUILD_ARCH" "${CROSS_COMPILE_ARG[@]}" -j"$JOBS" "$IMAGE_TARGET" modules 2>&1 | tee "$log"

    KERNEL_RELEASE="$(make -s -C "$work" ARCH="$BUILD_ARCH" "${CROSS_COMPILE_ARG[@]}" kernelrelease)"
    [[ -n "$KERNEL_RELEASE" ]] || error "Could not determine kernel release"

    local stage="$tmp/modules-staging"
    info "Installing modules to staging..."
    make -C "$work" ARCH="$BUILD_ARCH" "${CROSS_COMPILE_ARG[@]}" INSTALL_MOD_PATH="$stage" modules_install 2>&1 | tee -a "$log"

    local module_root="$stage/lib/modules/$KERNEL_RELEASE"
    [[ -d "$module_root" ]] || error "Missing staged modules at $module_root"

    MODULES_VHDX_TMP="$tmp/modules.vhdx"
    local modules_img="$tmp/modules.img"
    local modules_size
    modules_size="$(du -bs "$module_root" | awk '{print $1}')"
    modules_size=$((modules_size + 256 * 1024 * 1024))

    info "Creating module VHDX..."
    truncate -s "$modules_size" "$modules_img"
    mkfs.ext4 -F -d "$module_root" "$modules_img" >/dev/null
    qemu-img convert -O vhdx "$modules_img" "$MODULES_VHDX_TMP"
    qemu-img check "$MODULES_VHDX_TMP"
}

install_artifacts() {
    local work="$1"
    local artifact_id="$2"
    local kernel_file="$KERNEL_DEST/kernel-$artifact_id"
    local modules_file="$KERNEL_DEST/modules-$artifact_id.vhdx"

    mkdir -p "$KERNEL_DEST"
    cp "$work/$IMAGE_PATH" "$kernel_file"
    cp "$MODULES_VHDX_TMP" "$modules_file"

    local kernel_win
    local modules_win
    kernel_win="$(wslpath -w "$kernel_file" | tr '\\' '/')"
    modules_win="$(wslpath -w "$modules_file" | tr '\\' '/')"
    update_wslconfig "$kernel_win" "$modules_win"

    INSTALLED_KERNEL_PATH="$kernel_file"
    INSTALLED_MODULES_PATH="$modules_file"
    info "Installed kernel: $kernel_file"
    info "Installed module VHDX: $modules_file"
    info "Updated $WSLCONFIG"
}

install_downloaded_artifacts() {
    local kernel_src="$1"
    local modules_src="$2"
    local kernel_name="$3"
    local modules_name="$4"

    mkdir -p "$KERNEL_DEST"
    INSTALLED_KERNEL_PATH="$KERNEL_DEST/$kernel_name"
    INSTALLED_MODULES_PATH="$KERNEL_DEST/$modules_name"
    cp "$kernel_src" "$INSTALLED_KERNEL_PATH"
    cp "$modules_src" "$INSTALLED_MODULES_PATH"

    local kernel_win
    local modules_win
    kernel_win="$(wslpath -w "$INSTALLED_KERNEL_PATH" | tr '\\' '/')"
    modules_win="$(wslpath -w "$INSTALLED_MODULES_PATH" | tr '\\' '/')"
    update_wslconfig "$kernel_win" "$modules_win"

    info "Installed kernel: $INSTALLED_KERNEL_PATH"
    info "Installed module VHDX: $INSTALLED_MODULES_PATH"
    info "Updated $WSLCONFIG"
}

install_github_binary_release() {
    local tmp="$1"
    local release_metadata="$tmp/release-metadata.json"
    local kernel_tmp="$tmp/$GH_KERNEL_NAME"
    local modules_tmp="$tmp/$GH_MODULES_NAME"
    local source_branch=""
    local source_commit=""
    local kernel_release=""

    info "Downloading release metadata..."
    download_url "$GH_METADATA_URL" "$release_metadata"
    validate_release_metadata "$release_metadata" || error "Release metadata does not match requested target: $RELEASE_TAG"

    if [[ "$INSTALL" -ne 1 ]]; then
        info "Install was skipped; GitHub binary release is usable but no files were changed."
        return 0
    fi

    info "Downloading GitHub binary artifacts..."
    download_url "$GH_KERNEL_URL" "$kernel_tmp"
    download_url "$GH_MODULES_URL" "$modules_tmp"
    install_downloaded_artifacts "$kernel_tmp" "$modules_tmp" "$GH_KERNEL_NAME" "$GH_MODULES_NAME"

    source_branch="$(release_metadata_value "$release_metadata" '.port.source_branch')"
    source_commit="$(release_metadata_value "$release_metadata" '.port.commit')"
    kernel_release="$(release_metadata_value "$release_metadata" '.artifacts.kernel_release')"
    if [[ -z "$kernel_release" ]]; then
        kernel_release="${GH_KERNEL_NAME#kernel-}"
        kernel_release="${kernel_release%-$ARTIFACT_ARCH}"
    fi

    write_metadata \
        "$METADATA" \
        "$TARGET_LINUX_VERSION" "$TARGET_LINUX_TAG" \
        "$TARGET_WSL_VERSION" "$TARGET_WSL_TAG" "$TARGET_WSL_BASE_LINUX_TAG" \
        "$source_branch" "$source_commit" "$kernel_release" \
        "$INSTALLED_KERNEL_PATH" "$INSTALLED_MODULES_PATH"
    info "Wrote metadata: $METADATA"
    warn "Activation still requires: wsl.exe --shutdown"
}

build_github_source_release() {
    local tmp="$1"
    local release_metadata="$tmp/release-metadata.json"
    local source_tarball="$tmp/$GH_SOURCE_NAME"
    local work="$tmp/source"
    local source_branch=""
    local source_commit=""

    info "Downloading release metadata..."
    download_url "$GH_METADATA_URL" "$release_metadata"
    validate_release_metadata "$release_metadata" || error "Release metadata does not match requested target: $RELEASE_TAG"

    if [[ "$BUILD" -ne 1 ]]; then
        info "Build was skipped; GitHub source release is usable but no files were changed."
        return 0
    fi

    require_build_commands
    require_commands tar
    info "Downloading GitHub source artifact..."
    download_url "$GH_SOURCE_URL" "$source_tarball"
    mkdir -p "$work"
    tar -xzf "$source_tarball" -C "$work"

    # The published source artifact is packaged from the builder's working tree,
    # so it can carry prebuilt host tools and objects (scripts/kconfig/conf,
    # scripts/basic/fixdep, *.o) compiled for the builder's architecture. Reusing
    # those on a different host fails (e.g. "scripts/kconfig/conf: Syntax error:
    # "(" unexpected" when an x86-64 binary is exec'd on aarch64). Wipe all
    # generated artifacts and regenerate the config/host tools for THIS host
    # before building, mirroring the clean-tree local build path.
    info "Cleaning prebuilt host artifacts and regenerating config..."
    make -C "$work" ARCH="$BUILD_ARCH" "${CROSS_COMPILE_ARG[@]}" mrproper
    prepare_config "$work"

    build_kernel_and_modules "$work" "$tmp"

    if [[ "$INSTALL" -eq 1 ]]; then
        install_artifacts "$work" "$ARTIFACT_ID"
        source_branch="$(release_metadata_value "$release_metadata" '.port.source_branch')"
        source_commit="$(release_metadata_value "$release_metadata" '.port.commit')"
        write_metadata \
            "$METADATA" \
            "$TARGET_LINUX_VERSION" "$TARGET_LINUX_TAG" \
            "$TARGET_WSL_VERSION" "$TARGET_WSL_TAG" "$TARGET_WSL_BASE_LINUX_TAG" \
            "$source_branch" "$source_commit" "$KERNEL_RELEASE" \
            "$INSTALLED_KERNEL_PATH" "$INSTALLED_MODULES_PATH"
        info "Wrote metadata: $METADATA"
        warn "Activation still requires: wsl.exe --shutdown"
    else
        info "Install was skipped; installed-kernel metadata was left unchanged."
    fi
}

run_local_update() {
    [[ -d "$REPO_DIR/.git" || -f "$REPO_DIR/.git" ]] || error "Repo not found at $REPO_DIR"
    remote_exists "$LINUX_UPSTREAM_REMOTE" || error "Missing Linux upstream remote: $LINUX_UPSTREAM_REMOTE"
    remote_exists "$MSFT_REMOTE" || error "Missing Microsoft WSL remote: $MSFT_REMOTE"
    if [[ "$PUSH" -eq 1 ]]; then
        remote_exists "$WSL_FORK_REMOTE" || error "Missing WSL fork remote: $WSL_FORK_REMOTE"
    fi
    require_config_commands

    if [[ "$USE_FORK_CACHE" -eq 1 ]]; then
        fetch_tag_prefer "$LINUX_FORK_REMOTE" "$LINUX_UPSTREAM_REMOTE" "$TARGET_LINUX_TAG"
        fetch_tag_prefer "$LINUX_FORK_REMOTE" "$LINUX_UPSTREAM_REMOTE" "$TARGET_WSL_BASE_LINUX_TAG"
        fetch_tag_prefer "$WSL_FORK_REMOTE" "$MSFT_REMOTE" "$TARGET_WSL_TAG"
    else
        fetch_tag "$LINUX_UPSTREAM_REMOTE" "$TARGET_LINUX_TAG"
        fetch_tag "$LINUX_UPSTREAM_REMOTE" "$TARGET_WSL_BASE_LINUX_TAG"
        fetch_tag "$MSFT_REMOTE" "$TARGET_WSL_TAG"
    fi

    TARGET_LINUX_COMMIT="$(git -C "$REPO_DIR" rev-parse "$TARGET_LINUX_TAG^{commit}")"
    TARGET_WSL_BASE_LINUX_COMMIT="$(git -C "$REPO_DIR" rev-parse "$TARGET_WSL_BASE_LINUX_TAG^{commit}")"
    TARGET_WSL_COMMIT="$(git -C "$REPO_DIR" rev-parse "$TARGET_WSL_TAG^{commit}")"

    WORKTREE="$TMP_ROOT/linux"
    LOCAL_WORKTREE=1

    info "Creating temporary Linux-base worktree..."
    git -C "$REPO_DIR" worktree add --detach "$WORKTREE" "$TARGET_LINUX_COMMIT" >/dev/null

    info "Merging Microsoft WSL delta using $TARGET_WSL_BASE_LINUX_TAG as merge base..."
    set +e
    git -C "$WORKTREE" merge-recursive "$TARGET_WSL_BASE_LINUX_COMMIT" -- HEAD "$TARGET_WSL_COMMIT"
    merge_rc=$?
    set -e
    if [[ "$merge_rc" -ne 0 ]]; then
        resolve_known_conflicts "$WORKTREE"
    fi

    if [[ -n "$(git -C "$WORKTREE" diff --name-only --diff-filter=U)" ]]; then
        git -C "$WORKTREE" status --short >&2
        error "Unresolved conflicts remain after known WSL conflict handling."
    fi

    apply_known_compatibility_patches "$WORKTREE"
    prepare_config "$WORKTREE"

    write_metadata \
        "$WORKTREE/Microsoft/custom-wsl-port.json" \
        "$TARGET_LINUX_VERSION" "$TARGET_LINUX_TAG" \
        "$TARGET_WSL_VERSION" "$TARGET_WSL_TAG" "$TARGET_WSL_BASE_LINUX_TAG" \
        "$COMBINED_BRANCH" "" "" "" ""

    git -C "$WORKTREE" add -A
    TREE_ID="$(git -C "$WORKTREE" write-tree)"
    COMMIT_MSG="$(cat <<EOF
Port Linux $TARGET_LINUX_VERSION with Microsoft WSL $TARGET_WSL_VERSION

Linux base: $TARGET_LINUX_TAG
Microsoft WSL base: $TARGET_WSL_TAG
Microsoft WSL merge base: $TARGET_WSL_BASE_LINUX_TAG
Generated-by: update-custom-wsl-kernel.sh
EOF
)"
    COMBINED_COMMIT="$(printf '%s\n' "$COMMIT_MSG" | git -C "$WORKTREE" commit-tree "$TREE_ID" -p "$TARGET_LINUX_COMMIT" -p "$TARGET_WSL_COMMIT")"

    if [[ "$BUILD" -eq 1 ]]; then
        require_build_commands
        build_kernel_and_modules "$WORKTREE" "$TMP_ROOT"
    fi

    git -C "$REPO_DIR" update-ref "refs/heads/$COMBINED_BRANCH" "$COMBINED_COMMIT"
    info "Updated local branch $COMBINED_BRANCH -> $COMBINED_COMMIT"

    if [[ "$PUSH" -eq 1 ]]; then
        info "Pushing combined branch to $WSL_FORK_REMOTE..."
        git -C "$REPO_DIR" push "$WSL_FORK_REMOTE" "$COMBINED_BRANCH:$COMBINED_BRANCH"
    fi

    if [[ "$INSTALL" -eq 1 ]]; then
        install_artifacts "$WORKTREE" "$ARTIFACT_ID"
    fi

    if [[ -z "$KERNEL_RELEASE" && "$BUILD" -eq 0 ]]; then
        KERNEL_RELEASE="$(make -s -C "$WORKTREE" ARCH="${BUILD_ARCH:-arm64}" "${CROSS_COMPILE_ARG[@]}" kernelrelease 2>/dev/null || true)"
    fi

    if [[ "$INSTALL" -eq 1 ]]; then
        write_metadata \
            "$METADATA" \
            "$TARGET_LINUX_VERSION" "$TARGET_LINUX_TAG" \
            "$TARGET_WSL_VERSION" "$TARGET_WSL_TAG" "$TARGET_WSL_BASE_LINUX_TAG" \
            "$COMBINED_BRANCH" "$COMBINED_COMMIT" "$KERNEL_RELEASE" \
            "$INSTALLED_KERNEL_PATH" "$INSTALLED_MODULES_PATH"
        info "Wrote metadata: $METADATA"
        warn "Activation still requires: wsl.exe --shutdown"
    else
        info "Install was skipped; installed-kernel metadata was left unchanged."
    fi
}

require_commands git curl jq sort sed awk python3 wslpath

case "$SOURCE_MODE" in
    auto|github|local) ;;
    *) error "Unsupported source mode '$SOURCE_MODE'. Use auto, github, or local." ;;
esac

CURRENT_LINUX_VERSION="$(metadata_get '.linux.version')"
CURRENT_LINUX_TAG="$(metadata_get '.linux.tag')"
CURRENT_WSL_VERSION="$(metadata_get '.microsoft_wsl.version')"
CURRENT_WSL_TAG="$(metadata_get '.microsoft_wsl.tag')"
CURRENT_BRANCH="$(metadata_get '.combined.branch')"

if [[ -z "$CURRENT_LINUX_VERSION" ]]; then
    CURRENT_LINUX_VERSION="$(kernel_base_version "$(uname -r)")"
    CURRENT_LINUX_TAG="v$CURRENT_LINUX_VERSION"
fi

LATEST_LINUX_VERSION="$(latest_linux_stable_version)"
LATEST_WSL_VERSION="$(latest_wsl_version)"
TARGET_LINUX_VERSION="$LATEST_LINUX_VERSION"
TARGET_WSL_VERSION="$LATEST_WSL_VERSION"
TARGET_LINUX_TAG="${LINUX_TAG_OVERRIDE:-v$TARGET_LINUX_VERSION}"
TARGET_WSL_TAG="${WSL_TAG_OVERRIDE:-linux-msft-wsl-$TARGET_WSL_VERSION}"
TARGET_WSL_BASE_LINUX_TAG="$(wsl_base_linux_tag "$TARGET_WSL_VERSION")"
normalize_arch "${ARCH_OVERRIDE:-$HOST_UNAME_ARCH}"
COMBINED_BRANCH="linux-$TARGET_LINUX_VERSION-msft-wsl-$TARGET_WSL_VERSION"
ARTIFACT_ID="linux-$TARGET_LINUX_VERSION-msft-wsl-$TARGET_WSL_VERSION-$ARTIFACT_ARCH"
RELEASE_TAG="port/$ARTIFACT_ID"

LINUX_UPDATE=0
WSL_UPDATE=0
[[ -z "$CURRENT_LINUX_VERSION" || "$(version_gt "$TARGET_LINUX_VERSION" "$CURRENT_LINUX_VERSION" && echo yes || true)" == "yes" ]] && LINUX_UPDATE=1
[[ -z "$CURRENT_WSL_VERSION" || "$(version_gt "$TARGET_WSL_VERSION" "$CURRENT_WSL_VERSION" && echo yes || true)" == "yes" ]] && WSL_UPDATE=1

update_parts=()
[[ "$LINUX_UPDATE" -eq 1 ]] && update_parts+=("Linux ${CURRENT_LINUX_VERSION:-unknown} -> $TARGET_LINUX_VERSION")
[[ "$WSL_UPDATE" -eq 1 ]] && update_parts+=("WSL ${CURRENT_WSL_VERSION:-unknown} -> $TARGET_WSL_VERSION")

if [[ "$MODE" == "check" ]]; then
    if [[ ${#update_parts[@]} -gt 0 ]]; then
        echo -e "${YELLOW}[WSL Kernel] Custom port update available: $(join_update_parts "${update_parts[@]}")${NC}"
        echo -e "${YELLOW}  Run: bash $0${NC}"
    fi
    exit 0
fi

if [[ "$SOURCE_MODE" != "local" ]]; then
    inspect_github_release "$RELEASE_TAG" || true
fi
SELECTED_PATH="$(selected_update_path)"

if [[ "$MODE" == "status" || "$MODE" == "dry-run" ]]; then
    info "Installed Linux base: ${CURRENT_LINUX_VERSION:-unknown} (${CURRENT_LINUX_TAG:-unknown})"
    info "Installed WSL base: ${CURRENT_WSL_VERSION:-unknown} (${CURRENT_WSL_TAG:-unknown})"
    info "Latest Linux stable: $TARGET_LINUX_VERSION ($TARGET_LINUX_TAG)"
    info "Latest Microsoft WSL: $TARGET_WSL_VERSION ($TARGET_WSL_TAG)"
    info "Target architecture: $ARTIFACT_ARCH (make ARCH=$BUILD_ARCH, host=$HOST_UNAME_ARCH)"
    info "Builder release: $RELEASE_TAG ($(github_release_summary))"
    info "Selected update path: $SELECTED_PATH"
    if [[ ${#update_parts[@]} -eq 0 ]]; then
        info "No custom WSL port update is available."
    else
        info "Update needed: $(join_update_parts "${update_parts[@]}")"
    fi
    [[ "$MODE" == "status" || "$MODE" == "dry-run" ]] && exit 0
fi

if [[ "$FORCE" -eq 0 && ${#update_parts[@]} -eq 0 ]]; then
    info "No custom WSL port update is available."
    exit 0
fi

info "Target Linux base: $TARGET_LINUX_TAG"
info "Target Microsoft WSL base: $TARGET_WSL_TAG"
info "Target combined branch: $COMBINED_BRANCH"
info "Target builder release: $RELEASE_TAG ($(github_release_summary))"
info "Selected update path: $SELECTED_PATH"

if [[ "$YES" -ne 1 ]]; then
    read -rp "Build/install this custom WSL kernel? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { info "Aborted."; exit 0; }
fi

mkdir -p "$WORKDIR_BASE"
TMP_ROOT="$(mktemp -d "$WORKDIR_BASE/custom-wsl-kernel.XXXXXX")"
if [[ "$BUILD" -eq 1 && "$SELECTED_PATH" != "github-binary" ]]; then
    require_free_space "$TMP_ROOT" "$MIN_FREE_GIB"
fi
WORKTREE=""
LOCAL_WORKTREE=0
KERNEL_RELEASE=""
MODULES_VHDX_TMP=""
INSTALLED_KERNEL_PATH=""
INSTALLED_MODULES_PATH=""
CLEANUP_OK=0

cleanup() {
    local rc=$?
    if [[ "$CLEANUP_OK" -eq 1 ]]; then
        if [[ "$LOCAL_WORKTREE" -eq 1 && -n "${WORKTREE:-}" ]]; then
            git -C "$REPO_DIR" worktree remove --force "$WORKTREE" >/dev/null 2>&1 || true
        fi
        rm -rf "$TMP_ROOT"
    elif [[ "$rc" -ne 0 ]]; then
        warn "Update failed; worktree/logs retained at $TMP_ROOT"
    fi
}
trap cleanup EXIT

case "$SELECTED_PATH" in
    github-binary)
        install_github_binary_release "$TMP_ROOT"
        ;;
    github-source)
        build_github_source_release "$TMP_ROOT"
        ;;
    local)
        run_local_update
        ;;
    *)
        error "Internal error: unsupported selected update path '$SELECTED_PATH'"
        ;;
esac

CLEANUP_OK=1
