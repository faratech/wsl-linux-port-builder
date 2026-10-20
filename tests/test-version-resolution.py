from pathlib import Path
import json
import subprocess
import tempfile

repo_root = Path(__file__).resolve().parents[1]
updater_text = (repo_root / 'client/update-custom-wsl-kernel.sh').read_text()
port_text = (repo_root / 'scripts/port-wsl-kernel.sh').read_text()

# Extract functions needed from scripts/port-wsl-kernel.sh: tag_version, latest_linux_version
port_helpers = port_text[port_text.index('tag_version() {'):port_text.index('latest_wsl_version() {')]

# Extract functions from client/update-custom-wsl-kernel.sh
updater_helpers1 = updater_text[updater_text.index('kernel_base_version() {'):updater_text.index('normalize_arch() {')]
updater_helpers2 = updater_text[updater_text.index('tag_version() {'):updater_text.index('latest_wsl_version() {')]

cases = [
    {
        "name": "Linus initial release (7.3 in mainline, 7.2.11 in stable)",
        "payload": {
            "releases": [
                {"moniker": "mainline", "version": "7.3", "iseol": False},
                {"moniker": "stable", "version": "7.2.11", "iseol": False},
            ],
            "latest_stable": {"version": "7.3"},
        },
        "expected_stable": "7.3",
        "expected_mainline": "7.3",
    },
    {
        "name": "Point release (7.3.1 in stable, 7.4-rc1 in mainline)",
        "payload": {
            "releases": [
                {"moniker": "mainline", "version": "7.4-rc1", "iseol": False},
                {"moniker": "stable", "version": "7.3.1", "iseol": False},
                {"moniker": "stable", "version": "7.2.11", "iseol": False},
            ],
            "latest_stable": {"version": "7.3.1"},
        },
        "expected_stable": "7.3.1",
        "expected_mainline": "7.4-rc1",
    },
    {
        "name": "Legacy feed without latest_stable field",
        "payload": {
            "releases": [
                {"moniker": "stable", "version": "7.2.11", "iseol": False},
            ],
        },
        "expected_stable": "7.2.11",
        "expected_mainline": None,
    },
]

with tempfile.TemporaryDirectory() as tmp:
    tmp_path = Path(tmp)
    for c in cases:
        mock_file = tmp_path / "releases.json"
        mock_file.write_text(json.dumps(c["payload"]))

        # Test scripts/port-wsl-kernel.sh resolution
        cmd_stable = [
            "bash",
            "-c",
            f'{port_helpers}\n'
            f'die() {{ echo "$*" >&2; exit 1; }}\n'
            f'KERNEL_ORG_RELEASES="file://{mock_file}"\n'
            f'LINUX_TAG=""\n'
            f'LINUX_TRACK="stable"\n'
            f'latest_linux_version\n',
        ]
        res = subprocess.run(cmd_stable, capture_output=True, text=True, check=True)
        assert res.stdout.strip() == c["expected_stable"], (
            f"Failed {c['name']} (port stable): expected {c['expected_stable']}, got {res.stdout.strip()}"
        )

        if c["expected_mainline"]:
            cmd_mainline = [
                "bash",
                "-c",
                f'{port_helpers}\n'
                f'die() {{ echo "$*" >&2; exit 1; }}\n'
                f'KERNEL_ORG_RELEASES="file://{mock_file}"\n'
                f'LINUX_TAG=""\n'
                f'LINUX_TRACK="mainline"\n'
                f'latest_linux_version\n',
            ]
            res_m = subprocess.run(cmd_mainline, capture_output=True, text=True, check=True)
            assert res_m.stdout.strip() == c["expected_mainline"], (
                f"Failed {c['name']} (port mainline): expected {c['expected_mainline']}, got {res_m.stdout.strip()}"
            )

        # Test client/update-custom-wsl-kernel.sh resolution
        cmd_updater = [
            "bash",
            "-c",
            f'{updater_helpers2}\n'
            f'error() {{ echo "$*" >&2; exit 1; }}\n'
            f'KERNEL_ORG_RELEASES="file://{mock_file}"\n'
            f'LINUX_TAG_OVERRIDE=""\n'
            f'latest_linux_stable_version\n',
        ]
        res_u = subprocess.run(cmd_updater, capture_output=True, text=True, check=True)
        assert res_u.stdout.strip() == c["expected_stable"], (
            f"Failed {c['name']} (updater): expected {c['expected_stable']}, got {res_u.stdout.strip()}"
        )

# Test version normalization and comparison helpers
helper_test = f'''
set -euo pipefail
{updater_helpers1}
{updater_helpers2}

# Normalization of X.Y.0 to X.Y
[[ "$(tag_version v7.3)" == "7.3" ]]
[[ "$(tag_version 7.3)" == "7.3" ]]
[[ "$(tag_version v7.3.0)" == "7.3" ]]
[[ "$(tag_version 7.3.0)" == "7.3" ]]
[[ "$(tag_version v7.3.1)" == "7.3.1" ]]
[[ "$(tag_version linux-msft-wsl-6.18.54.1)" == "6.18.54.1" ]]

[[ "$(kernel_base_version "7.3.0-microsoft-standard-WSL2+")" == "7.3" ]]
[[ "$(kernel_base_version "7.2.11-microsoft-standard-WSL2-dirty")" == "7.2.11" ]]
[[ "$(kernel_base_version "7.3.1-microsoft-standard-WSL2")" == "7.3.1" ]]

# version_gt comparisons
version_gt 7.3 7.2.11
version_gt 7.3.0 7.2.11
version_gt 7.3.1 7.3
version_gt 7.3.1 7.3.0
! version_gt 7.3 7.3.0
! version_gt 7.3.0 7.3
! version_gt 7.3 7.3
! version_gt 7.2.11 7.3
'''
subprocess.run(['bash', '-c', helper_test], check=True)

print("PASS: test-version-resolution passed all assertions.")
