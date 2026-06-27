# Repository Guidelines

## Project Structure & Module Organization

This repository automates custom WSL kernel port generation without maintaining
fork mirrors.

- `scripts/port-wsl-kernel.sh` contains the main resolver, source generator, and
  build/package logic.
- `.github/workflows/build-custom-wsl-kernel.yml` runs scheduled and manual
  GitHub Actions jobs.
- `client/` holds the consumer side: `update-custom-wsl-kernel.sh` (installs a
  published port on a WSL host), `wsl-kernel-check.sh` (login update-check hook),
  and `install.sh` (sets both up).
- `docs/architecture.md` explains the upstream-fetch and merge flow.
- `patches/README.md` is reserved for future compatibility patch queues.
- Generated outputs belong in temporary or ignored output directories, such as
  `out/`, `dist/`, or `/tmp/wsl-port`; do not commit kernel tarballs, patches, or
  VHDX artifacts unless explicitly intended.

## Build, Test, and Development Commands

- `bash -n scripts/port-wsl-kernel.sh` checks shell syntax.
- `python3 - <<'PY' ... yaml.safe_load(...) ... PY` can validate workflow YAML
  when `python3-yaml` is available.
- `scripts/port-wsl-kernel.sh --mode resolve --linux-track stable --arch arm64`
  resolves the latest Linux and Microsoft WSL targets without fetching sources.
- `scripts/port-wsl-kernel.sh --mode source --linux-tag v7.1.1 --wsl-tag linux-msft-wsl-6.18.35.2 --arch arm64 --output-dir /tmp/wsl-port`
  generates metadata, release notes, a source patch, and a source tarball.
- `scripts/port-wsl-kernel.sh --mode build --linux-track stable --arch arm64 --output-dir /tmp/wsl-port`
  builds the kernel image and module VHDX; this is slower and requires build
  dependencies such as `qemu-utils`.

## Coding Style & Naming Conventions

Use Bash with `set -euo pipefail`, quoted variables, arrays for argument lists,
and small helper functions. Keep generated names predictable:
`linux-<linux-version>-msft-wsl-<wsl-version>-<arch>`,
`port/<name>`, and `generated/<name>`. Prefer explicit architecture names:
`arm64` for ARM64 artifacts and `x64` for x86_64 artifacts.

## Testing Guidelines

There is no formal test framework yet. Before pushing, run shell syntax checks,
workflow YAML parsing, `--mode resolve`, and at least one source-generation smoke
test for the changed path. For merge logic changes, verify the generated patch
applies cleanly to the selected Linux tag with `git apply --check`.

## Commit & Pull Request Guidelines

Use short, imperative commit messages matching the existing history, for example
`Install ARM64 cross compiler for source generation`. Pull requests should state
what changed, why it changed, which commands or Actions runs validated it, and
whether release artifact formats or workflow inputs changed.

## Security & Configuration Tips

Do not commit credentials, GitHub tokens, downloaded upstream source trees, or
large generated kernel artifacts. Keep release publication in GitHub Actions
using `GITHUB_TOKEN` and repository-scoped permissions.
