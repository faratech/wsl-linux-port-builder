# WSL Linux Port Builder

Automation for building a custom WSL2 kernel from two upstream sources:

- kernel.org Linux stable or mainline
- Microsoft `WSL2-Linux-Kernel`

The repository does not require forks of either upstream. GitHub Actions fetches the
requested upstream tags directly, applies Microsoft WSL changes on top of the Linux
base, applies the maintained compatibility rules in `scripts/port-wsl-kernel.sh`,
and publishes build artifacts.

## How It Works

This repo treats the custom WSL kernel as a combination of two independently
moving inputs:

- the latest selected Linux stable or mainline tag, for example `v7.1.3`
- the latest Microsoft WSL kernel release tag, for example
  `linux-msft-wsl-6.18.35.2`

For each Linux/WSL/architecture combination, the builder creates a release named:

```text
port/linux-<linux-version>-msft-wsl-<wsl-version>-<arch>
```

Examples:

- `port/linux-7.1.3-msft-wsl-6.18.35.2-arm64`
- `port/linux-7.1.3-msft-wsl-6.18.35.2-x64`

The scheduled GitHub workflow runs every 6 hours. By default it resolves the
current Linux and Microsoft WSL versions, then generates source releases for both
`arm64` and `x64`. Each release contains metadata, release notes, a patch against
the selected Linux tag, and a source tarball with the WSL delta already applied.
Manual workflow runs can target one architecture or build full installable
kernel/module artifacts.

On a WSL machine, `client/update-custom-wsl-kernel.sh` checks installed metadata
against the latest Linux and WSL inputs. Its default `--source auto` mode prefers
published GitHub release artifacts. If the matching release does not exist yet,
it clones or updates this public builder repo under `/var/tmp`, runs
`scripts/port-wsl-kernel.sh` locally for the requested Linux/WSL/arch target, and
then builds/installs from that generated source. It does not require the old
`WSL2-Linux-Kernel` fork checkout.

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

`.github/workflows/build-custom-wsl-kernel.yml` runs every 6 hours and generates
both `arm64` and `x64` source releases by default. Manual runs can target one
architecture or `all`, and can optionally build full kernel/module artifacts.
