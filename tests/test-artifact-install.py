from pathlib import Path
import subprocess
import tempfile

# Exercise the installer helpers without invoking network resolution or a build.
script = (Path(__file__).resolve().parents[1] / 'client/update-custom-wsl-kernel.sh').read_text()
helpers=script[script.index('update_wslconfig() {'):script.index('write_metadata() {')]
helpers+=script[script.index('install_artifacts() {'):script.index('install_github_binary_release() {')]
with tempfile.TemporaryDirectory() as tmp:
    path=Path(tmp)
    (path/'helpers.sh').write_text(helpers)
    test=r'''set -euo pipefail
source ./helpers.sh
info() { :; }
error() { echo "$*" >&2; exit 1; }
wslpath() { printf '%s\n' "$2"; }
KERNEL_DEST="$PWD/destination"
WSLCONFIG="$PWD/wslconfig"
mkdir "$KERNEL_DEST"
printf old-kernel > "$KERNEL_DEST/kernel-test"
printf old-modules > "$KERNEL_DEST/modules-test.vhdx"
printf '[wsl2]\nkernel=old\nkernelModules=old\nmemory=56GB\n[experimental]\nnetworkingMode=mirrored\n' > "$WSLCONFIG"
printf new-kernel > kernel-source
printf new-modules > modules-source
install_downloaded_artifacts kernel-source modules-source kernel-test modules-test.vhdx
first_kernel="$INSTALLED_KERNEL_PATH"
first_modules="$INSTALLED_MODULES_PATH"
cmp kernel-source "$first_kernel"
cmp modules-source "$first_modules"
install_downloaded_artifacts kernel-source modules-source kernel-test modules-test.vhdx
[[ "$first_kernel" != "$INSTALLED_KERNEL_PATH" ]]
[[ "$(cat "$KERNEL_DEST/kernel-test")" == old-kernel ]]
[[ "$(cat "$KERNEL_DEST/modules-test.vhdx")" == old-modules ]]
grep -Fx "kernel=$INSTALLED_KERNEL_PATH" "$WSLCONFIG"
grep -Fx 'memory=56GB' "$WSLCONFIG"
grep -Fx 'networkingMode=mirrored' "$WSLCONFIG"
cp "$WSLCONFIG" config-before
# A failure during the second copy must never activate an incomplete pair.
if bash -ec '
source ./helpers.sh
info() { :; }
error() { exit 1; }
cp() { if [[ "$1" == modules-source ]]; then return 1; fi; command cp "$@"; }
KERNEL_DEST="$PWD/destination"
WSLCONFIG="$PWD/wslconfig"
install_downloaded_artifacts kernel-source modules-source kernel-test modules-test.vhdx
'; then
    echo 'Expected module copy failure' >&2; exit 1
fi
cmp config-before "$WSLCONFIG"
IMAGE_PATH=kernel-source
MODULES_VHDX_TMP="$PWD/modules-source"
install_artifacts "$PWD" local-test
cmp kernel-source "$INSTALLED_KERNEL_PATH"
cmp modules-source "$INSTALLED_MODULES_PATH"
printf 'PASS: repeated installs, existing files, config preservation, copy failure, local install\n'
'''
    subprocess.run(['bash','-c',test],cwd=path,check=True)
