from pathlib import Path
import subprocess
import tempfile

# Exercise the merge-conflict resolvers in both scripts against a synthetic
# repo shaped like the Linux 7.3.1 / WSL 6.18.58.1 netvsc.c conflict.
root = Path(__file__).resolve().parents[1]
for script_name, fail_fn in (('scripts/port-wsl-kernel.sh', 'die'),
                             ('client/update-custom-wsl-kernel.sh', 'error')):
    script = (root / script_name).read_text()
    helpers = script[script.index('resolve_superset_conflicts() {'):script.index('apply_known_compatibility_patches() {')]
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp)
        (path / 'helpers.sh').write_text(helpers)
        test = r'''set -euo pipefail
source ./helpers.sh
warn() { :; }
FAIL_FN() { echo "$*" >&2; exit 1; }
ensure_dxg_entries() { :; }
git init -q repo
cd repo
git config user.name test
git config user.email test@example.invalid
# Use a non-diff3 marker style; the resolver must not depend on user config.
git config merge.conflictStyle zdiff3
mkdir -p drivers/net/hyperv
f=drivers/net/hyperv/netvsc.c
printf '#include "hyperv_net.h"\n\n/* switch datapath */\nint a;\n' > "$f"
printf 'base\n' > other.c
git add -A && git commit -qm base && base=$(git rev-parse HEAD)
printf '#include "hyperv_net.h"\n\nstatic struct workqueue_struct *netvsc_wq;\n\n/* switch datapath */\nint a;\n' > "$f"
printf 'linux\n' > other.c
git commit -qam linux && linux=$(git rev-parse HEAD)
git checkout -q "$base"
printf '#include "hyperv_net.h"\n\nstatic struct workqueue_struct *netvsc_wq;\n\nstatic int helper(void)\n{\n\treturn 0;\n}\n\n/* switch datapath */\nint a;\n' > "$f"
printf 'wsl\n' > other.c
git commit -qam wsl && wsl=$(git rev-parse HEAD)
expected=$(git show "$wsl:$f")

git checkout -q "$linux"
git merge-recursive "$base" -- HEAD "$wsl" >/dev/null 2>&1 && { echo 'Expected conflict' >&2; exit 1; }
if (resolve_known_conflicts "$PWD") 2>err; then
    echo 'Expected unknown other.c to be refused' >&2; exit 1
fi
grep -q 'Unknown WSL/Linux merge conflict in other.c' err

git checkout -qf "$linux"
printf 'base\n' > other.c
git commit -qam 'drop other.c change'
git merge-recursive "$base" -- HEAD "$wsl" >/dev/null 2>&1 && { echo 'Expected conflict' >&2; exit 1; }
git diff --name-only --diff-filter=U | grep -qFx "$f"
git diff --name-only --diff-filter=U | grep -qFxv "$f" && { echo "Unexpected conflicts" >&2; exit 1; }
resolve_known_conflicts "$PWD"
[[ -z "$(git diff --name-only --diff-filter=U)" ]]
[[ "$(cat "$f")" == "$expected" ]]
[[ "$(grep -c netvsc_wq "$f")" == 1 ]]

# Linux deleting lines that Microsoft changed must not be auto-resolved.
git checkout -qf "$base"
printf '#include "hyperv_net.h"\n\nint a;\n' > "$f"
git commit -qam 'linux deletes' && linux3=$(git rev-parse HEAD)
git checkout -q "$base"
printf '#include "hyperv_net.h"\n\n/* switch datapath to VF */\nint a;\n' > "$f"
git commit -qam 'wsl modifies' && wsl3=$(git rev-parse HEAD)
git checkout -q "$linux3"
git merge-recursive "$base" -- HEAD "$wsl3" >/dev/null 2>&1 && { echo 'Expected conflict' >&2; exit 1; }
if (resolve_known_conflicts "$PWD") 2>err; then
    echo 'Expected delete/modify conflict to be refused' >&2; exit 1
fi
grep -q 'not a superset' err
grep -q '^|||||||' "$f"
printf 'PASS: SCRIPT superset resolution, unknown file refusal, delete/modify refusal\n'
'''.replace('FAIL_FN', fail_fn).replace('SCRIPT', script_name)
        subprocess.run(['bash', '-c', test], cwd=path, check=True)
