# homebrew-tap

Homebrew tap for [editz](https://github.com/beprajwal/editz). The editz source repository is private; its release
files (standalone binaries, `install.sh`) are published here by the editz release workflow. Everything in this repo
is generated.

```bash
brew install beprajwal/tap/editz
# or without Homebrew:
curl -fsSL https://raw.githubusercontent.com/beprajwal/homebrew-tap/main/install.sh | bash
```

Binaries: the platforms each release lists in its notes (`releases/download/editz-vX.Y.Z/editz-vX.Y.Z-<os>-<arch>.tar.gz`
with a `.sha256` next to each). On a platform without one, `install.sh` and `brew` stop with a clear message; use
`install.sh --uv` (the Python wheel) there.

editz needs a few tools Homebrew does not pull in for you:

- `brew install ffmpeg-full` on macOS for burned-in text (libass); distro ffmpeg usually has it
- a container runtime for the Insta360 SDK image: apple/container (`brew install container`, plus Rosetta), Docker
  Desktop / Colima / OrbStack, or docker/podman on Linux
- your own Insta360 SDK download for `editz build-image --vendor <dir>` (proprietary, not distributed)
- `editz fonts sync` for text overlay fonts

Then run `editz doctor`.

Binaries downloaded with a browser (not curl or Homebrew) get macOS's quarantine flag; clear it with
`xattr -dr com.apple.quarantine <dir>`.
