#!/usr/bin/env bash
# editz installer.
#   curl -fsSL https://raw.githubusercontent.com/beprajwal/homebrew-tap/main/install.sh | bash
#   bash -s -- --version v0.1.1 --dry-run
# Default: downloads the standalone binary tarball for this OS/arch (public tap release), verifies its sha256 and
# unpacks it under <prefix>/share/editz/<version>, with <prefix>/bin/editz linked to its editz-bin. No uv, no sudo.
# --uv / --wheel / --extras instead `uv tool install` the Python wheel (the private-repo path). Missing runtime tools
# (ffmpeg, libass, container runtime, Rosetta/qemu) are reported with install commands, never installed for you.
set -euo pipefail

REPO="${EDITZ_REPO:-beprajwal/editz}"
TAP="${EDITZ_TAP:-beprajwal/homebrew-tap}"      # public tap holding the release files (release tag editz-vX.Y.Z)
RELEASE_URL="${EDITZ_RELEASE_URL:-}"   # base holding <tag>/<asset>; optional LATEST file names the newest tag
PREFIX="${EDITZ_PREFIX:-$HOME/.local}"
MODE="binary"
VERSION="latest"
EXTRAS=""
WHEEL=""
DRY_RUN=0
MODIFY_PATH=1

usage() {
  cat <<EOF
Usage: install.sh [options]

Options:
  --version <vX.Y.Z|X.Y.Z|latest>  Release to install (default: latest)
  --prefix <dir>                   Install under <dir>/share/editz and <dir>/bin (default: ~/.local)
  --uv                             Install the Python wheel with uv instead of the binary
  --extras <a,b>                   Optional extras (implies --uv): agents, vision
  --wheel <path>                   Install this local wheel with uv instead of downloading (implies --uv)
  --dry-run                        Print what would happen; change nothing
  --no-modify-path                 Do not let the uv installer edit your shell profile
  -h, --help                       Show this help

Environment:
  EDITZ_TAP           Public repo hosting the release files (default: beprajwal/homebrew-tap)
  EDITZ_REPO          Private source repo, only a fallback download source (default: beprajwal/editz)
  EDITZ_PREFIX        Same as --prefix
  EDITZ_RELEASE_URL   Download base: <url>/<tag>/<asset> (http(s):// or file://); <url>/LATEST holds the newest tag
  GITHUB_TOKEN / GH_TOKEN   Token for the private repo when the public tap is unreachable and gh is not logged in

Downloads need no login: release files are public on the tap. Which platforms have a binary is decided per release
by the files that release actually carries; a platform without one gets a clear message (use --uv for the wheel).
EOF
}

log() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
run() { if [ "$DRY_RUN" = 1 ]; then printf '[dry-run] %s\n' "$*"; else "$@"; fi; }

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --version) [ $# -ge 2 ] || die "--version needs a value"; VERSION="$2"; shift 2 ;;
    --prefix) [ $# -ge 2 ] || die "--prefix needs a directory"; PREFIX="$2"; shift 2 ;;
    --uv) MODE="uv"; shift ;;
    --extras) [ $# -ge 2 ] || die "--extras needs a value"; EXTRAS="$2"; MODE="uv"; shift 2 ;;
    --wheel) [ $# -ge 2 ] || die "--wheel needs a path"; WHEEL="$2"; MODE="uv"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --no-modify-path) MODIFY_PATH=0; shift ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
done

case "$PREFIX" in /*) ;; *) PREFIX="${PWD}/${PREFIX#./}" ;; esac

if [ -n "$EXTRAS" ] && ! [[ "$EXTRAS" =~ ^[a-z][a-z0-9_,-]*$ ]]; then
  die "invalid --extras '$EXTRAS' (use e.g. agents,vision)"
fi

OS="$(uname -s)"
ARCH="$(uname -m)"
case "$OS" in Darwin) T_OS=macos ;; Linux) T_OS=linux ;; *) T_OS="" ;; esac
case "$ARCH" in arm64|aarch64) T_ARCH=arm64 ;; x86_64|amd64) T_ARCH=x86_64 ;; *) T_ARCH="" ;; esac
TARGET="${T_OS}-${T_ARCH}"
if [ "$MODE" = binary ]; then
  [ -n "$T_OS" ] && [ -n "$T_ARCH" ] || die "no binary for ${OS}/${ARCH}; use --uv (or --wheel <file>) to install the Python wheel instead"
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/editz-install.XXXXXX")"
STAGING=""
trap 'rm -rf "$TMP"' EXIT

# --- uv -------------------------------------------------------------------------------------------
ensure_uv() {
  command -v uv >/dev/null 2>&1 && return 0
  for dir in "${XDG_BIN_HOME:-}" "$HOME/.local/bin" "$HOME/.cargo/bin"; do
    if [ -n "$dir" ] && [ -x "$dir/uv" ]; then PATH="$dir:$PATH"; return 0; fi
  done
  log "uv is not installed"
  if [ "$DRY_RUN" = 0 ] && [ -r /dev/tty ] && [ -t 1 ]; then
    local answer=""
    printf 'Install uv with the official installer (https://astral.sh/uv)? [Y/n] ' >/dev/tty
    read -r answer </dev/tty || answer=""
    case "$answer" in n|N|no|NO) die "uv is required: https://docs.astral.sh/uv/getting-started/installation/" ;; *) ;; esac
  fi
  command -v curl >/dev/null 2>&1 || die "curl is required to install uv"
  if [ "$DRY_RUN" = 1 ]; then
    printf '[dry-run] curl -LsSf https://astral.sh/uv/install.sh | %ssh\n' "$([ "$MODIFY_PATH" = 0 ] && echo 'UV_NO_MODIFY_PATH=1 ')"
    return 0
  fi
  if [ "$MODIFY_PATH" = 0 ]; then
    curl -LsSf https://astral.sh/uv/install.sh | UV_NO_MODIFY_PATH=1 sh
  else
    curl -LsSf https://astral.sh/uv/install.sh | sh
  fi
  PATH="${XDG_BIN_HOME:-$HOME/.local/bin}:$HOME/.local/bin:$PATH"
  command -v uv >/dev/null 2>&1 || die "uv was installed but is not on PATH; open a new shell and re-run"
}

# --- release resolution ---------------------------------------------------------------------------
gh_ready() { command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; }
token() { printf '%s' "${GITHUB_TOKEN:-${GH_TOKEN:-}}"; }

api() { # api <path> [extra curl args...]
  local path="$1"; shift
  curl -fsSL -H "Authorization: Bearer $(token)" -H "X-GitHub-Api-Version: 2022-11-28" "$@" "https://api.github.com/repos/${REPO}/${path}"
}

tap_latest() { # newest stable (non-draft, non-prerelease) editz-vX.Y.Z release on the public tap, as vX.Y.Z
  curl -fsSL "https://api.github.com/repos/${TAP}/releases?per_page=30" 2>/dev/null \
    | tr '\n' ' ' \
    | sed 's/"tag_name"/\
@@/g' \
    | sed -n 's/^@@ *: *"editz-\(v[^"]*\)"\(.*\)$/\1|\2/p' \
    | grep -E '"prerelease": *false' | grep -E '"draft": *false' \
    | head -1 | cut -d'|' -f1
}

private_hint() {
  cat >&2 <<EOF
error: could not download editz ${1:-} from ${TAP} or ${REPO}.
The public tap has no such release and the source repository is private (anonymous downloads 404). Do one of:
  - gh auth login        (install gh: https://cli.github.com), then re-run
  - export GITHUB_TOKEN=<token with repo read access>, then re-run
  - set EDITZ_RELEASE_URL to a mirror, or use --wheel <path> with a downloaded wheel
EOF
  exit 1
}

resolve_tag() {
  case "$VERSION" in
    latest) ;;
    v*) printf '%s' "$VERSION"; return 0 ;;
    *) printf 'v%s' "$VERSION"; return 0 ;;
  esac
  local tag=""
  if [ -n "$RELEASE_URL" ]; then
    tag="$(curl -fsSL "${RELEASE_URL%/}/LATEST" 2>/dev/null | tr -d '[:space:]')" || tag=""
  elif tag="$(tap_latest)" && [ -n "$tag" ]; then
    :
  elif gh_ready; then
    tag="$(gh release view --repo "$REPO" --json tagName --jq .tagName 2>/dev/null)" || tag=""
  elif [ -n "$(token)" ]; then
    tag="$(api releases/latest 2>/dev/null | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)" || tag=""
  else
    tag="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/${REPO}/releases/latest" 2>/dev/null | sed -n 's#.*/tag/\(.*\)#\1#p')" || tag=""
  fi
  [ -n "$tag" ] || private_hint "(latest)"
  printf '%s' "$tag"
}

fetch_asset() { # fetch_asset <tag> <asset name> [tap|any]: leaves the file in $TMP
  local tag="$1" name="$2"
  if [ -n "$RELEASE_URL" ]; then
    curl -fsSL "${RELEASE_URL%/}/${tag}/${name}" -o "$TMP/$name" || die "cannot fetch ${RELEASE_URL%/}/${tag}/${name}"
  elif curl -fsSL "https://github.com/${TAP}/releases/download/editz-${tag}/${name}" -o "$TMP/$name" 2>/dev/null; then
    :
  elif gh_ready; then
    gh release download "$tag" --repo "$REPO" --pattern "$name" --dir "$TMP" >/dev/null || private_hint "$tag"
  elif [ -n "$(token)" ]; then
    local asset
    asset="$(api "releases/tags/${tag}" | awk -v n="$name" '/"url": *"[^"]*\/releases\/assets\/[0-9]+"/ { u=$2; gsub(/[",]/, "", u) } index($0, "\"name\": \"" n "\"") { print u; exit }')" || asset=""
    [ -n "$asset" ] || die "no asset ${name} on release ${tag} of ${REPO} (token valid? tag exists?)"
    curl -fsSL -H "Authorization: Bearer $(token)" -H "Accept: application/octet-stream" "$asset" -o "$TMP/$name" || private_hint "$tag"
  else
    curl -fsSL "https://github.com/${REPO}/releases/download/${tag}/${name}" -o "$TMP/$name" 2>/dev/null || private_hint "$tag"
  fi
  [ -f "$TMP/$name" ] || die "download of ${name} produced no file"
}

download_wheel() { # prints the wheel path
  local tag="$1" name="editz-${1#v}-py3-none-any.whl"
  fetch_asset "$tag" "$name"
  printf '%s' "$TMP/$name"
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# 0 = the requested release has this asset, 1 = it does not, 2 = cannot tell (offline, private fallback ...)
release_has_asset() { # release_has_asset <tag> <name>
  local tag="$1" name="$2" url code=0
  if [ -n "$RELEASE_URL" ]; then
    url="${RELEASE_URL%/}/${tag}/${name}"
  else
    url="https://github.com/${TAP}/releases/download/editz-${tag}/${name}"
  fi
  case "$url" in
    file://*) if [ -f "${url#file://}" ]; then return 0; else return 1; fi ;;
  esac
  curl -fsSIL -o /dev/null "$url" 2> /dev/null || code=$?
  case "$code" in
    0) return 0 ;;
    22)
      # a missing asset only counts when the release itself exists (otherwise: wrong version, private, or offline)
      if [ -z "$RELEASE_URL" ] && curl -fsSIL -o /dev/null "https://github.com/${TAP}/releases/tag/editz-${tag}" 2> /dev/null; then
        return 1
      fi
      return 2 ;;
    *) return 2 ;;
  esac
}

install_binary() { # install_binary <tag>
  local tag="$1" ver="${1#v}"
  local base="editz-${tag}-${TARGET}"
  local have=0
  release_has_asset "$tag" "${base}.tar.gz" || have=$?
  if [ "$have" = 1 ]; then
    die "release ${tag} has no ${TARGET} binary (${base}.tar.gz); use --uv (or --wheel <file>) to install the Python wheel, or pick another --version"
  fi
  local dest="${PREFIX}/share/editz/${ver}-<id>" link="${PREFIX}/bin/editz"
  if [ "$DRY_RUN" = 1 ]; then
    printf '[dry-run] download %s.tar.gz (+ .sha256) for %s\n' "$base" "$tag"
    printf '[dry-run] verify sha256, unpack to %s, link %s -> %s/editz-bin\n' "$dest" "$link" "$dest"
    return 0
  fi
  fetch_asset "$tag" "${base}.tar.gz"
  fetch_asset "$tag" "${base}.tar.gz.sha256"
  local want got
  want="$(cut -d' ' -f1 "$TMP/${base}.tar.gz.sha256")"
  got="$(sha256_of "$TMP/${base}.tar.gz")"
  if [ -z "$want" ] || [ "$want" != "$got" ]; then
    die "sha256 mismatch for ${base}.tar.gz (expected ${want:-<none>}, got ${got})"
  fi
  log "sha256 ok"
  mkdir -p "$TMP/unpack" "${PREFIX}/share/editz" "${PREFIX}/bin"
  tar -xzf "$TMP/${base}.tar.gz" -C "$TMP/unpack"
  [ -x "$TMP/unpack/${base}/editz-bin" ] || die "tarball has no ${base}/editz-bin"
  # Every attempt gets its own immutable directory; a live install dir is never renamed or deleted. The only
  # change to the installed state is one atomic rename of the launcher symlink, after the candidate has run.
  local uniq final status=0 out previous=""
  uniq="$(date +%Y%m%d%H%M%S).$$"
  STAGING="${PREFIX}/share/editz/.staging-${uniq}"
  trap 'rm -rf "$TMP" "${STAGING:-}"' EXIT   # cleans up only this run's own directories
  mv "$TMP/unpack/${base}" "$STAGING"
  if [ "$OS" = "Darwin" ]; then xattr -dr com.apple.quarantine "$STAGING" 2>/dev/null || true; fi
  out="$("$STAGING/editz-bin" --version 2>&1)" || status=$?
  if [ "$status" != 0 ]; then
    die "the downloaded editz failed to run (exit ${status}): ${out}. Your existing install was left untouched."
  fi
  final="${PREFIX}/share/editz/${ver}-${uniq}"
  mv "$STAGING" "$final"
  STAGING=""
  if [ -L "$link" ]; then previous="$(readlink "$link")"; fi
  ln -s "${final}/editz-bin" "${link}.new.${uniq}"
  mv -f "${link}.new.${uniq}" "$link"
  if [ ! -x "$link" ]; then
    if [ -n "$previous" ]; then ln -sfn "$previous" "$link"; fi
    die "installed link ${link} does not resolve to an executable; restored the previous launcher"
  fi
  # best effort, after success: drop version dirs the launcher no longer points at
  local d
  for d in "${PREFIX}"/share/editz/*; do
    if [ -d "$d" ] && [ "$d" != "$final" ]; then rm -rf "$d" || true; fi
  done
  log "installed ${final} (linked ${link})"
  case ":$PATH:" in *":${PREFIX}/bin:"*) ;; *) warn "${PREFIX}/bin is not on PATH; add it to your shell profile" ;; esac
}

# --- main -----------------------------------------------------------------------------------------
if [ "$MODE" = uv ]; then
ensure_uv

if [ -n "$WHEEL" ]; then
  [ -f "$WHEEL" ] || die "wheel not found: $WHEEL"
  WHEEL="$(cd "$(dirname "$WHEEL")" && pwd)/$(basename "$WHEEL")"
  log "using local wheel $WHEEL"
else
  TAG="$(resolve_tag)"
  log "release ${TAG}"
  if [ "$DRY_RUN" = 1 ]; then
    WHEEL="$TMP/editz-${TAG#v}-py3-none-any.whl"
    printf '[dry-run] download editz-%s-py3-none-any.whl for %s\n' "${TAG#v}" "$TAG"
  else
    WHEEL="$(download_wheel "$TAG")"
  fi
fi

SPEC="editz"
[ -z "$EXTRAS" ] || SPEC="editz[${EXTRAS}]"
log "installing ${SPEC} with uv tool"
run uv tool install --force "${SPEC} @ ${WHEEL}"
else
  TAG="$(resolve_tag)"
  log "release ${TAG} (${TARGET} binary)"
  install_binary "$TAG"
fi

# --- runtime dependencies (reported, never installed) -----------------------------------------------
missing=""
need() { missing="${missing}$(printf '  - %s\n      %s\n' "$1" "$2")"$'\n'; }

has_libass() {
  local ff="$1"
  [ -x "$ff" ] || return 1
  local filters
  filters="$("$ff" -hide_banner -filters 2>/dev/null)" || return 1
  grep -qE '^ [^ ]+ (ass|subtitles) ' <<<"$filters"
}

report_deps() {
  log "checking runtime dependencies"
  local brew_hint="brew install"
  if [ "$OS" = "Darwin" ] && ! command -v brew >/dev/null 2>&1; then
    need "Homebrew" "see https://brew.sh for the one-line installer"
  fi
  if ! command -v ffmpeg >/dev/null 2>&1; then
    if [ "$OS" = "Darwin" ]; then need "ffmpeg" "$brew_hint ffmpeg"; else need "ffmpeg" "sudo apt-get install ffmpeg   (or your distro's package)"; fi
  fi
  local ff_ok=0 ff
  for ff in "$(command -v ffmpeg 2>/dev/null || true)" ${EDITZ_FFMPEG_FULL:-/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg /usr/local/opt/ffmpeg-full/bin/ffmpeg}; do
    [ -n "$ff" ] && has_libass "$ff" && ff_ok=1 && break
  done
  if [ "$ff_ok" = 0 ]; then
    if [ "$OS" = "Darwin" ]; then
      need "ffmpeg with libass (burned-in text; plain ffmpeg lacks it)" "$brew_hint ffmpeg-full"
    else
      need "ffmpeg with libass (burned-in text)" "install an ffmpeg build with --enable-libass"
    fi
  fi
  if [ "$OS" = "Darwin" ]; then
    if ! command -v container >/dev/null 2>&1 && ! command -v docker >/dev/null 2>&1; then
      need "a container runtime (runs the Insta360 SDK image)" \
        "$brew_hint container   (apple/container; or Docker Desktop / Colima / OrbStack)"
    fi
    if command -v container >/dev/null 2>&1 && [ "$ARCH" = "arm64" ] && ! /usr/bin/pgrep -q oahd 2>/dev/null; then
      need "Rosetta 2 (apple/container runs the amd64 SDK image through it)" "softwareupdate --install-rosetta --agree-to-license"
    fi
  else
    if ! command -v docker >/dev/null 2>&1 && ! command -v podman >/dev/null 2>&1; then
      need "docker or podman (runs the Insta360 SDK image)" \
        "sudo apt-get install docker.io   (or: sudo dnf install podman); then: sudo usermod -aG docker \"\$USER\" and re-login"
    fi
    case "$ARCH" in
      aarch64|arm64) [ -e /proc/sys/fs/binfmt_misc/qemu-x86_64 ] || need "amd64 emulation (the SDK image is amd64)" \
        "sudo apt-get install qemu-user-static   (or: docker run --privileged --rm tonistiigi/binfmt --install amd64)" ;;
      *) ;;
    esac
  fi
  if [ -z "$missing" ]; then
    log "all runtime dependencies found"
  else
    printf 'Missing runtime dependencies (not installed for you; run the commands you need):\n%s' "$missing"
  fi
}
report_deps

if [ "$DRY_RUN" = 1 ]; then
  log "dry run finished; nothing was changed"
  exit 0
fi

if [ "$MODE" = uv ]; then
  tool_bin="$(uv tool dir --bin 2>/dev/null || true)"
  case ":$PATH:" in *":${tool_bin}:"*) ;; *) [ -z "$tool_bin" ] || warn "${tool_bin} is not on PATH; run \`uv tool update-shell\` or add it yourself" ;; esac
  BIN="${tool_bin:+$tool_bin/}editz"
else
  BIN="${PREFIX}/bin/editz"
fi
status=0
version_out="$("$BIN" --version 2>&1)" || status=$?
[ "$status" = 0 ] || die "the installed editz failed to run (exit ${status}): ${version_out}"
log "installed: ${version_out}"
echo "Next: run \`editz doctor\` to check your setup."
