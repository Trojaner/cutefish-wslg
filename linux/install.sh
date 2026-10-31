#!/usr/bin/env bash
# Builds the Cutefish applications from source, with the patches in this
# repository, and installs them as Debian packages for use under WSLg.
#
#   linux/install.sh [--channel stable|nightly] [--yes]
#   linux/install.sh --uninstall [--yes]
#
# stable builds the upstream commits the submodules pin; nightly builds the
# newest commit of every upstream project. Run as root.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE=/var/lib/cutefish-wslg
CACHE=/var/cache/cutefish-wslg
WORK="$CACHE/build"
PIN_FILE=/etc/apt/preferences.d/cutefish-wslg

# The projects built, named as in upstream/packaging/versions; build.sh puts
# them in dependency order.
COMPONENTS=(
  cutefish-toolkit cutefish-framework icons wallpapers
  calculator filemanager settings system-monitor terminal text-editor
)
BUILD_PACKAGES=(build-essential ca-certificates curl devscripts equivs git python3 xz-utils)
# The session bus single-instance apps use, fonts the theme names, and the
# SVG renderer for the WSLg icons.
RUNTIME_PACKAGES=(dbus-user-session fonts-noto-core fonts-noto-mono librsvg2-bin)

channel=stable
assume_yes=false
action=install

usage() {
  sed -n '2,9s/^# \{0,1\}//p' "${BASH_SOURCE[0]}"
}

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

while (( $# )); do
  case "$1" in
    --channel) channel="${2:-}"; shift ;;
    --channel=*) channel="${1#*=}" ;;
    --yes|-y) assume_yes=true ;;
    --uninstall) action=uninstall ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; die "unknown option $1" ;;
  esac
  shift
done
[[ "$channel" == stable || "$channel" == nightly ]] || die "--channel is stable or nightly, not '$channel'"
(( EUID == 0 )) || die "run as root, e.g. sudo $0"

confirm() {
  [[ "$assume_yes" == true ]] && return 0
  [[ -t 0 ]] || die "not a terminal; pass --yes to run without asking"
  local answer
  read -r -p "$1 [y/N] " answer
  [[ "$answer" == [yY]* ]] || die "cancelled"
}

check_os() {
  # shellcheck source=/dev/null
  . /etc/os-release
  case "${ID:-}" in
    debian) [[ "${VERSION_ID:-}" == 13 ]] && return 0 ;;
    ubuntu) dpkg --compare-versions "${VERSION_ID:-0}" ge 26.04 && return 0 ;;
  esac
  die "${PRETTY_NAME:-this distribution} is not supported; Cutefish needs Debian 13 or Ubuntu 26.04 or newer"
}

check_systemd() {
  if [[ "$(ps -p 1 -o comm=)" != systemd ]]; then
    printf 'Warning: systemd is not running, so there is no session bus; Settings and the\n' >&2
    printf 'Text Editor need one. Set systemd=true under [boot] in /etc/wsl.conf.\n' >&2
  fi
}

# Clones a checkout into the workspace at the commit the channel names.
prepare_source() {
  local project="$1" src="$ROOT/upstream/$1" dst="$WORK/$1" commit url
  commit="$(git -C "$src" rev-parse --verify --quiet HEAD)" \
    || die "upstream/$project is not checked out; clone this repository with --recurse-submodules"
  git clone --quiet --no-checkout "$src" "$dst"
  if [[ "$channel" == nightly ]]; then
    url="$(git -C "$src" config --get remote.origin.url)"
    git -C "$dst" fetch --quiet --depth 1 "$url" HEAD
    commit="$(git -C "$dst" rev-parse FETCH_HEAD)"
  fi
  git -C "$dst" checkout --quiet --detach "$commit"
  printf '  %-20s %s\n' "$project" "$(git -C "$dst" log -1 --format='%h %cs %s' | cut -c1-60)"
}

# Applies patches/<project>/*.patch as commits. They keep the upstream
# commit's date, which build.sh versions snapshots by.
apply_patches() {
  local project="$1" dst="$WORK/$1" patch date
  date="$(git -C "$dst" log -1 --format=%cI HEAD)"
  for patch in "$ROOT/patches/$project"/*.patch; do
    [[ -f "$patch" ]] || continue
    if ! GIT_COMMITTER_DATE="$date" git -C "$dst" \
        -c user.name=cutefish-wslg -c user.email=cutefish-wslg@localhost -c commit.gpgsign=false \
        am --quiet "$patch"; then
      git -C "$dst" am --abort || true
      die "$(basename "$patch") no longer applies to $project at $(git -C "$dst" rev-parse --short HEAD); use --channel stable"
    fi
    printf '  %-20s + %s\n' "$project" "$(basename "$patch")"
  done
}

# The toolkit builds a pinned Skia, kept between runs since it is large.
fetch_skia() {
  local third_party="$WORK/cutefish-toolkit/third_party"
  mkdir -p "$third_party" "$CACHE"
  if [[ -d "$CACHE/skia/.git" ]]; then
    mv "$CACHE/skia" "$third_party/skia"
  fi
  "$WORK/cutefish-toolkit/scripts/fetch-skia.sh"
}

stash_skia() {
  if [[ -d "$WORK/cutefish-toolkit/third_party/skia/.git" && ! -e "$CACHE/skia" ]]; then
    mv "$WORK/cutefish-toolkit/third_party/skia" "$CACHE/skia"
  fi
}

# Upstream's nightly APT repository would replace the patched toolkit with
# its own, which does not start under WSLg; keep the one built here.
pin_toolkit() {
  if grep -rqs 'download\.cutefish\.org' /etc/apt/sources.list /etc/apt/sources.list.d/; then
    cat > "$PIN_FILE" <<'EOF'
# Written by cutefish-wslg: the toolkit from download.cutefish.org lacks the
# WSLg patches; the one cutefish-wslg builds stays installed.
Package: cutefish-toolkit
Pin: origin download.cutefish.org
Pin-Priority: -1
EOF
    log "Pinned cutefish-toolkit away from download.cutefish.org ($PIN_FILE)"
  fi
}

built_packages() {
  local changes deb arch
  arch="$(dpkg-architecture -qDEB_HOST_ARCH)"
  for changes in "$WORK/packaging/out/debian"/*_"$arch".changes; do
    dcmd --deb "$changes"
  done | while read -r deb; do
    [[ "$deb" == *-dbgsym_* ]] || basename "$deb" | cut -d_ -f1
  done | sort -u
}

do_install() {
  check_os
  log "Installing Cutefish for WSLg ($channel channel)"
  confirm "Build and install the Cutefish applications? This takes a while."
  check_systemd

  export DEBIAN_FRONTEND=noninteractive
  log "Installing build tools"
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends "${BUILD_PACKAGES[@]}" "${RUNTIME_PACKAGES[@]}" >/dev/null

  log "Preparing sources"
  rm -rf "$WORK"
  mkdir -p "$WORK" "$STATE"
  trap stash_skia EXIT
  for project in "${COMPONENTS[@]}" packaging; do
    prepare_source "$project"
  done
  for project in "${COMPONENTS[@]}"; do
    apply_patches "$project"
  done
  fetch_skia

  pin_toolkit
  log "Building and installing packages"
  # A snapshot of an earlier commit sorts below what may be installed.
  printf 'APT::Get::Allow-Downgrades "true";\n' > "$WORK/apt.conf"
  APT_CONFIG="$WORK/apt.conf" "$WORK/packaging/debian/build.sh" --install --snapshot "${COMPONENTS[@]}"
  built_packages > "$STATE/packages"
  printf '%s\n' "$channel" > "$STATE/channel"

  log "Rendering the application icons for WSLg"
  "$ROOT/linux/cutefish-wslg-icons"

  log "Installed"
  # shellcheck disable=SC2046
  dpkg-query -W -f='  ${Package} ${Version}\n' $(cat "$STATE/packages")
  printf '\nThe applications are in the Windows Start menu once WSLg reloads; from Windows:\n'
  printf '  wsl --terminate %s\n' "${WSL_DISTRO_NAME:-<distro>}"
}

do_uninstall() {
  [[ -f "$STATE/packages" ]] || die "nothing to uninstall: $STATE/packages is missing"
  confirm "Remove the Cutefish packages cutefish-wslg installed?"
  export DEBIAN_FRONTEND=noninteractive
  # shellcheck disable=SC2046
  apt-get purge -y $(cat "$STATE/packages")
  apt-get autoremove -y --purge
  if [[ -f "$STATE/pixmaps" ]]; then
    xargs -r -d '\n' rm -f -- < "$STATE/pixmaps"
  fi
  rm -f "$PIN_FILE"
  rm -rf "$STATE" "$CACHE"
  log "Removed"
}

"do_$action"
