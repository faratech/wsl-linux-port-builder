# WSL Linux Port Builder

Automation for building a custom WSL2 kernel from two upstream sources:

- kernel.org Linux stable or mainline
- Microsoft `WSL2-Linux-Kernel`

The repository does not require forks of either upstream. GitHub Actions fetches the
requested upstream tags directly, applies Microsoft WSL changes on top of the Linux
base, applies the maintained compatibility rules in `scripts/port-wsl-kernel.sh`,
and publishes build artifacts.

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
