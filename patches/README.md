# Compatibility Patch Queue

The builder currently uses deterministic compatibility rules embedded in
`scripts/port-wsl-kernel.sh` for the known Microsoft WSL to newer-Linux conflicts.

If future Linux API drift requires real source patches, add them here and teach the
script to apply them in order after the Microsoft WSL delta is merged.
