# Architecture

This repo is the source of truth for the custom WSL port automation.

It intentionally avoids depending on forks:

1. Resolve the target Linux release from kernel.org.
2. Resolve the target Microsoft WSL release from GitHub.
3. Fetch the matching Linux tags from kernel.org stable Git.
4. Fetch the Microsoft WSL release tag from `microsoft/WSL2-Linux-Kernel`.
5. Create a temporary worktree at the Linux tag.
6. Merge Microsoft's WSL delta using the Microsoft release's vanilla Linux base tag.
7. Apply known compatibility rules.
8. Build and package artifacts when requested.

The workflow publishes a patch against the selected Linux tag and a source
tarball. Generated source branches can be pushed from this repo later if we want
permanent source snapshots, but the build does not require mirror forks.
