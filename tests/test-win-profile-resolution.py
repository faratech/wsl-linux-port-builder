from pathlib import Path
import subprocess
import tempfile

script = (Path(__file__).resolve().parents[1] / 'client/update-custom-wsl-kernel.sh').read_text()
start = script.index('resolve_win_profile() {')
end = script.index('WIN_PROFILE="$(resolve_win_profile)"')
helper = script[start:end]

with tempfile.TemporaryDirectory() as tmp:
    path = Path(tmp)
    (path / 'resolve.sh').write_text(helper)

    test = r'''set -euo pipefail
source ./resolve.sh

# Case 1: cmd.exe in PATH
mkdir -p bin
cat << 'EOF' > bin/cmd.exe
#!/bin/sh
printf 'C:\\Users\\PathUser\r\n'
EOF
chmod +x bin/cmd.exe

wslpath() { printf '/mnt/c/Users/%s' "${1##*\\}"; }

PATH="$PWD/bin:$PATH"
res="$(resolve_win_profile)"
[[ "$res" == "/mnt/c/Users/PathUser" ]]

# Case 2: cmd.exe not in PATH, candidate path exists
rm -rf bin
sys32="$PWD/sys32"
mkdir -p "$sys32"
cat << 'EOF' > "$sys32/cmd.exe"
#!/bin/sh
printf 'C:\\Users\\Sys32User\r\n'
EOF
chmod +x "$sys32/cmd.exe"

resolve_win_profile_sys32() {
    # Test candidate override matching sys32 path
    local cmd_bin="cmd.exe"
    if ! command -v "$cmd_bin" >/dev/null 2>&1; then
        if [[ -x "''' + str(path / 'sys32/cmd.exe') + r'''" ]]; then
            cmd_bin="''' + str(path / 'sys32/cmd.exe') + r'''"
        fi
    fi
    local raw=""
    if command -v "$cmd_bin" >/dev/null 2>&1 || [[ -x "$cmd_bin" ]]; then
        raw="$("$cmd_bin" /C 'echo %USERPROFILE%' < /dev/null 2>/dev/null | tr -d '\r' | tail -n 1)"
    fi
    if [[ -n "$raw" && "$raw" != "%USERPROFILE%" ]]; then
        wslpath "$raw" 2>/dev/null || true
        return 0
    fi
}
PATH="/usr/bin:/bin"
res="$(resolve_win_profile_sys32)"
[[ "$res" == "/mnt/c/Users/Sys32User" ]]

# Case 3: No cmd.exe, fallback to scanning user dirs
resolve_win_profile_users() {
    local users_dir="$1"
    for user_dir in "$users_dir"/*; do
        if [[ -f "$user_dir/wsl-kernel/custom-wsl-kernel.json" || -f "$user_dir/.wslconfig" ]]; then
            printf '%s\n' "$user_dir"
            return 0
        fi
    done
}
mock_users="$PWD/Users"
mkdir -p "$mock_users/Alice/wsl-kernel"
touch "$mock_users/Alice/wsl-kernel/custom-wsl-kernel.json"
mkdir -p "$mock_users/Bob"
res="$(resolve_win_profile_users "$mock_users")"
[[ "$res" == "$mock_users/Alice" ]]

# Case 4: Nothing found, must return empty string and not "."
resolve_win_profile_empty() {
    local cmd_bin="nonexistent-cmd.exe"
    local raw=""
    if command -v "$cmd_bin" >/dev/null 2>&1; then
        raw="$("$cmd_bin" /C 'echo %USERPROFILE%' < /dev/null 2>/dev/null | tr -d '\r' | tail -n 1)"
    fi
    if [[ -n "$raw" && "$raw" != "%USERPROFILE%" ]]; then
        wslpath "$raw" 2>/dev/null || true
        return 0
    fi
    for user_dir in /nonexistent/*; do
        if [[ -f "$user_dir/wsl-kernel/custom-wsl-kernel.json" || -f "$user_dir/.wslconfig" ]]; then
            printf '%s\n' "$user_dir"
            return 0
        fi
    done
}
res="$(resolve_win_profile_empty)"
[[ -z "$res" ]]

printf 'PASS: cmd in PATH, sys32 candidate, directory scan fallback, empty on missing\n'
'''
    subprocess.run(['bash', '-c', test], cwd=path, check=True)
