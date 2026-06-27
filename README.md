# WSL Linux Port Builder

Automation for building a custom WSL2 kernel from two upstream sources:

- kernel.org Linux stable or mainline
- Microsoft `WSL2-Linux-Kernel`

The repository does not require forks of either upstream. GitHub Actions fetches the
requested upstream tags directly, applies Microsoft WSL changes on top of the Linux
base, applies the maintained compatibility rules in `scripts/port-wsl-kernel.sh`,
and publishes build artifacts.

## Install

To consume the published ports on a WSL machine, use the client installer in
`client/`. It places the updater on `PATH` and wires up a login-time update
check (`/etc/profile.d/wsl-kernel-check.sh`).

From a checkout:

```bash
sudo client/install.sh
```

Standalone (no clone):

```bash
curl -fsSL https://raw.githubusercontent.com/faratech/wsl-linux-port-builder/main/client/install.sh | sudo bash
```

Options: `--prefix DIR` (updater location, default `/usr/local/bin`),
`--no-check` (skip the login hook), `--uninstall`. After installing, run an
update any time with `update-custom-wsl-kernel.sh` (see `--help` for `--check`,
`--status`, `--dry-run`, `--arch`, and source-mode flags).

The login hook prefers the updater's own `--check`; if the updater is not
installed it shows a generic notice comparing the running kernel to the latest
stock Microsoft WSL release, and stays quiet on a custom-port kernel.

## Manual Usage

Resolve the current targets without building:

```bash
scripts/port-wsl-kernel.sh --mode resolve --linux-track stable --arch arm64
```

Generate a combined source tree without building:

```bash
scripts/port-wsl-kernel.sh --mode source --linux-track stable --arch arm64 --output-dir /tmp/wsl-port
```

Build artifacts:

```bash
scripts/port-wsl-kernel.sh --mode build --linux-track stable --arch arm64 --output-dir /tmp/wsl-port
```

## Outputs

Build mode writes:

- `metadata.json`
- `kernel-<release>-<arch>`
- `modules-<release>-<arch>.vhdx`
- `build.log`

Source mode writes:

- `metadata.json`
- `release-notes.md`
- `patch-<port>.patch`
- `source-<port>.tar.gz`

## GitHub Actions

`.github/workflows/build-custom-wsl-kernel.yml` runs every 6 hours and supports
manual inputs for Linux track, tags, WSL release tag, architecture, and whether to
build full artifacts.
