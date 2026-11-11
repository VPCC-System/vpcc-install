#!/bin/bash
# vpcc-install: the one line a person pastes into Terminal to install VPCC.
#
#   curl -fsSL https://raw.githubusercontent.com/VPCC-System/vpcc-install/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/VPCC-System/vpcc-install/main/install.sh | bash -s -- --dry-run
#
# What it does (README.md explains each step for a person deciding whether to paste it):
#   1. checks this Mac (macOS 15 or newer, Apple Silicon or Intel, /usr/bin/jq present)
#   2. installs Apple's Command Line Tools if missing (one macOS dialog; about 10 min, assumed)
#   3. installs GitHub CLI (gh) into ~/.vpcc/bin if it isn't there (official zip, checksum checked)
#   4. logs in to GitHub in the browser (gh auth login) and checks you can see the private vpcc repo
#   5. downloads the newest good VPCC release, checks its checksum, unpacks it into
#      ~/.vpcc/releases/<version>/ and points the link ~/.vpcc/setup at it
#   6. runs the real installer from that release: ~/.vpcc/setup/install.sh
#
# Options (after `bash -s --`): --dry-run (print the steps; download and change nothing),
#   --yes (don't ask before starting; passed on to the real installer), --help.
#
# Safety: the whole script is inside main(), called on the last line as `{ main "$@"; }`: a download
# cut anywhere (even right after "main") is an unfinished command, so bash runs nothing.
# No admin rights (no sudo). Answers are read from the terminal (/dev/tty), never
# from stdin (stdin is this script). Errors start with "vpcc-install: " and say how to fix them.
#
# bash 3.2 + /usr/bin/jq + stock macOS tools. Every outside command goes through a variable so
# the tests (tests/run.sh) can replace it with a stub.

# TODO(owner): set the real GitHub org before the first push (DESIGN B.2).
VPCC_ORG="${VPCC_ORG:-VPCC-System}"

# GitHub CLI pinned for the download (only used when gh isn't already installed).
# Checked 11-11: gh_2.103.3_checksums.txt from https://github.com/cli/cli/releases = own download.
GH_VERSION="${GH_VERSION:-2.103.3}"
GH_SHA256_ARM64="${GH_SHA256_ARM64:-d700207eae9ae98fe2b89535c2c087c07823d4628c56364695a5a07ef311c062}"
GH_SHA256_AMD64="${GH_SHA256_AMD64:-a2f86418f4350ae6e9ec60d5000bdf7665728436946a97fc27fe50e6ae752682}"

VPCC_TTY="${VPCC_TTY:-/dev/tty}"
VPCC_CURL="${VPCC_CURL:-/usr/bin/curl}"
VPCC_SHASUM="${VPCC_SHASUM:-/usr/bin/shasum}"
VPCC_TAR="${VPCC_TAR:-/usr/bin/tar}"
VPCC_DITTO="${VPCC_DITTO:-/usr/bin/ditto}"
VPCC_XCODE_SELECT="${VPCC_XCODE_SELECT:-/usr/bin/xcode-select}"
VPCC_DSCL="${VPCC_DSCL:-/usr/bin/dscl}"
VPCC_UNAME="${VPCC_UNAME:-/usr/bin/uname}"
VPCC_SW_VERS="${VPCC_SW_VERS:-/usr/bin/sw_vers}"
VPCC_JQ="${VPCC_JQ:-/usr/bin/jq}"
VPCC_ID="${VPCC_ID:-/usr/bin/id}"
VPCC_SLEEP="${VPCC_SLEEP:-/bin/sleep}"
VPCC_CLT_POLL="${VPCC_CLT_POLL:-20}"      # seconds between Command Line Tools checks
VPCC_CLT_MAX="${VPCC_CLT_MAX:-1800}"      # give up after 30 min (assumed: the install takes ~10)

# gh prints "A new release of gh is available" in the middle of our output (Homebrew gh, seen 11-11,
# finding 13 of TESTS #66): off for every gh call here and in the VPCC installer this runs (exported).
export GH_NO_UPDATE_NOTIFIER=1

VI_VERSION_RE='^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+(\.[0-9A-Za-z]+)*)?$'
VI_LINE='curl -fsSL https://raw.githubusercontent.com/VPCC-System/vpcc-install/main/install.sh | bash'

vi_say()  { printf '%s\n' "$*"; }
# vi_gh <args>: a gh call that must never ask anything (status, setup-git, api). `gh auth login` is
# the one interactive call and runs without this.
vi_gh() { GH_PROMPT_DISABLED=1 "$VI_GH" "$@"; }
vi_step() { printf '\n==> %s\n' "$*"; }
vi_die()  { printf 'vpcc-install: %s\n' "$*" >&2; vi_cleanup; exit 1; }

# vi_rm <path>: removes only this run's own temp folders (never anything else).
vi_rm() {
  case "$1" in
    # tar keeps the archive's folder modes: a read-only folder (e.g. 555) would make rm fail, so
    # give this run's own temp tree write access first (-P: never follow a link out of it).
    "$VPCC_HOME"/releases/.incoming.*|"$VPCC_HOME"/bin/.gh-incoming.*)
      chmod -R -P u+rwX "$1" 2>/dev/null; rm -rf "$1" ;;
    *) printf 'vpcc-install: refusing to delete %s (not a temp folder of this run)\n' "$1" >&2 ;;
  esac
}
VI_TEMPS=""
vi_cleanup() {
  local t
  [ -n "$VI_TEMPS" ] || return 0
  while IFS= read -r t; do [ -n "$t" ] && [ -e "$t" ] && vi_rm "$t"; done <<EOF
$VI_TEMPS
EOF
  VI_TEMPS=""
}
vi_temp() { VI_TEMPS="$VI_TEMPS
$1"; }

# vi_ask <question>: y/n from the terminal (VPCC_TTY), default yes. --yes answers yes.
vi_ask() {
  local ans=""
  [ "$VI_YES" = 1 ] && return 0
  printf '%s [Y/n] ' "$1"
  if ! { IFS= read -r ans < "$VPCC_TTY"; } 2>/dev/null; then
    printf '\n'
    vi_die "there is no terminal to ask (couldn't read $VPCC_TTY). Paste the line into the Terminal app, or answer yes up front with --yes, e.g. ${VI_LINE% | bash} | bash -s -- --yes"
  fi
  case "$ans" in ""|y|Y|yes|Yes|YES) return 0 ;; esac
  return 1
}

vi_usage() {
  cat <<EOF
vpcc-install: installs VPCC on this Mac.
  $VI_LINE
  ... | bash -s -- --dry-run   print the steps; download and change nothing
  ... | bash -s -- --yes       don't ask before starting (also passed to the real installer)
EOF
}

vi_resolve() { (cd "$1" 2>/dev/null && pwd -P); }

# vi_abs <absolute path>: the path with its existing part resolved (links, ".", ".."), the part that
# doesn't exist yet appended as written ("." parts dropped). Callers refuse ".." in that part.
vi_abs() {
  local p="$1" rest="" base r
  while [ ! -d "$p" ]; do
    case "$p" in /|"") break ;; esac
    base="${p##*/}"; p="${p%/*}"; [ -n "$p" ] || p=/
    case "$base" in ""|.) ;; *) rest="/$base$rest" ;; esac
  done
  r="$(vi_resolve "$p")" || r="$p"
  r="${r%/}$rest"
  printf '%s\n' "${r:-/}"
}
# vi_under <path> <folder>: true when path is the folder or inside it (both already vi_abs'd).
vi_under() { [ "$1" = "$2" ] || case "$1" in "${2%/}"/*) true ;; *) false ;; esac; }

# ---- safety latch: never test against the real home ------------------------------------------------
# Refuses when this run uses a development source (VPCC_INSTALL_SOURCE, a local tarball) or runs
# under the tests (VPCC_BOOTSTRAP_TEST) AND either HOME is the current user's real home, or
# VPCC_HOME points into the real home outside the scratch HOME (e.g. VPCC_HOME=~/.vpcc left in
# the environment after a real install). The real home comes from the user database (dscl) for the
# real user id (id -un), never from $HOME or $USER, which the environment can change.
# VPCC_INSTALL_I_KNOW=1 overrides. If the real home can't be read, it refuses too (fails closed).
vi_latch() {
  local who real mine vh
  [ -n "${VPCC_INSTALL_SOURCE:-}" ] || [ -n "${VPCC_BOOTSTRAP_TEST:-}" ] || return 0
  [ "${VPCC_INSTALL_I_KNOW:-}" = 1 ] && return 0
  who="$("$VPCC_ID" -un 2>/dev/null)"
  [ -n "$who" ] && real="$("$VPCC_DSCL" . -read "/Users/$who" NFSHomeDirectory 2>/dev/null | /usr/bin/sed -n 's/^NFSHomeDirectory: *//p' | /usr/bin/head -n 1)"
  case "${real:-}" in
    /*) ;;
    *) vi_die "safety latch: couldn't read the real home folder of ${who:-this user}, and this is a development or test run (VPCC_INSTALL_SOURCE or VPCC_BOOTSTRAP_TEST is set). Nothing was changed. Run it with HOME set to a scratch folder, e.g. HOME=/tmp/vpcc-try, or set VPCC_INSTALL_I_KNOW=1 if you really mean it." ;;
  esac
  real="$(vi_abs "$real")"
  mine="$(vi_abs "$HOME")"
  if [ "$real" = "$mine" ]; then
    vi_die "safety latch: HOME is your real home ($HOME) and this is a development or test run (VPCC_INSTALL_SOURCE or VPCC_BOOTSTRAP_TEST is set). Nothing was changed. Use a scratch HOME, e.g. HOME=/tmp/vpcc-try, or set VPCC_INSTALL_I_KNOW=1 if you really mean it."
  fi
  # A scratch HOME inside the real home (e.g. ~/vpcc-test) is fine; VPCC_HOME must stay inside it.
  vh="$(vi_abs "$VPCC_HOME")"
  if vi_under "$vh" "$real" && ! vi_under "$vh" "$mine"; then
    vi_die "safety latch: VPCC_HOME ($VPCC_HOME) is inside your real home ($real), outside the scratch HOME ($HOME), and this is a development or test run. Nothing was changed. Unset it (unset VPCC_HOME, so it becomes \$HOME/.vpcc) or point it into the scratch HOME, e.g. VPCC_HOME=\"\$HOME/.vpcc\"."
  fi
}

# ---- 1. this Mac --------------------------------------------------------------------------------
vi_check_mac() {
  local os ver major
  os="$("$VPCC_UNAME" -s 2>/dev/null)"
  [ "$os" = Darwin ] || vi_die "VPCC runs on macOS only (this system says: ${os:-unknown}). Paste the line on your Mac."
  VI_ARCH="$("$VPCC_UNAME" -m 2>/dev/null)"
  case "$VI_ARCH" in
    arm64) VI_GH_ARCH=arm64; VI_GH_SHA="$GH_SHA256_ARM64" ;;
    # (assumed) Intel Macs work the same way; the design targets Apple Silicon (DESIGN 2), so untested.
    x86_64) VI_GH_ARCH=amd64; VI_GH_SHA="$GH_SHA256_AMD64" ;;
    *) vi_die "this Mac's processor type ($VI_ARCH) isn't supported; VPCC needs an Apple Silicon (arm64) Mac." ;;
  esac
  ver="$("$VPCC_SW_VERS" -productVersion 2>/dev/null)"
  major="${ver%%.*}"
  case "$major" in ''|*[!0-9]*) vi_die "couldn't read the macOS version (sw_vers said: ${ver:-nothing}). Check Apple menu > About This Mac; VPCC needs macOS 15 or newer." ;; esac
  # (assumed) macOS 15+ (DESIGN 2): it ships /usr/bin/jq, which every VPCC hook needs.
  [ "$major" -ge 15 ] || vi_die "VPCC needs macOS 15 or newer; this Mac has macOS $ver. Update in System Settings > General > Software Update, then paste the line again."
  [ -x "$VPCC_JQ" ] || vi_die "$VPCC_JQ is missing (it comes with macOS 15 and newer). Update macOS in System Settings > General > Software Update, then paste the line again."
  vi_say "macOS $ver on $VI_ARCH: ok"
}

# ---- 2. Command Line Tools ----------------------------------------------------------------------
vi_clt() {
  local waited=0 polls=0
  if "$VPCC_XCODE_SELECT" -p >/dev/null 2>&1; then vi_say "Command Line Tools: already installed"; return 0; fi
  if [ "$VI_DRY" = 1 ]; then
    vi_say "[dry-run] would run \`xcode-select --install\` (a macOS dialog; click Install) and wait for it (about 10 min, assumed)"
    return 0
  fi
  vi_say "Apple's Command Line Tools are missing (they give this Mac a real \`git\`)."
  vi_say "A macOS dialog opens now: click \"Install\" (not \"Get Xcode\") and accept the licence."
  vi_say "It takes about 10 minutes (assumed). This window waits; one dot per minute."
  # It fails when the request is already open (e.g. the dialog from an earlier try): keep waiting.
  "$VPCC_XCODE_SELECT" --install >/dev/null 2>&1 || true
  while ! "$VPCC_XCODE_SELECT" -p >/dev/null 2>&1; do
    if [ "$waited" -ge "$VPCC_CLT_MAX" ]; then
      printf '\n'
      vi_die "the Command Line Tools still aren't installed after $((VPCC_CLT_MAX / 60)) minutes. If you closed the dialog, run \`xcode-select --install\` in Terminal, finish it, then paste the install line again. Nothing else was changed."
    fi
    "$VPCC_SLEEP" "$VPCC_CLT_POLL"
    waited=$((waited + VPCC_CLT_POLL)); polls=$((polls + 1))
    [ $(( (polls * VPCC_CLT_POLL) % 60 )) -lt "$VPCC_CLT_POLL" ] && printf '.'
  done
  [ "$polls" -gt 0 ] && printf '\n'
  vi_say "Command Line Tools: installed"
}

# ---- 3. GitHub CLI ------------------------------------------------------------------------------
# Sets VI_GH. Order: VPCC_GH, then gh on PATH, then $VPCC_HOME/bin/gh, else the pinned download.
vi_gh_find() {
  if [ -n "${VPCC_GH:-}" ]; then VI_GH="$VPCC_GH"; return 0; fi
  VI_GH="$(command -v gh 2>/dev/null)" && [ -n "$VI_GH" ] && return 0
  if [ -x "$VPCC_HOME/bin/gh" ]; then VI_GH="$VPCC_HOME/bin/gh"; return 0; fi
  VI_GH=""; return 1
}

vi_gh_install() {
  local name url dir inc got found n
  if vi_gh_find; then vi_say "GitHub CLI: $VI_GH"; return 0; fi
  name="gh_${GH_VERSION}_macOS_${VI_GH_ARCH}"
  url="https://github.com/cli/cli/releases/download/v${GH_VERSION}/${name}.zip"
  dir="$VPCC_HOME/bin/gh-$GH_VERSION"
  if [ "$VI_DRY" = 1 ]; then
    vi_say "[dry-run] would download GitHub CLI $GH_VERSION ($url), check its checksum and put it in $dir, linked as $VPCC_HOME/bin/gh"
    return 0
  fi
  case "$VI_GH_SHA" in
    *[!0-9a-f]*|'') vi_die "this copy of the installer has no checksum for GitHub CLI $GH_VERSION ($VI_GH_ARCH) yet (TODO-verify), so it won't download it. Tell the VPCC owner. Nothing was changed." ;;
  esac
  [ "${#VI_GH_SHA}" = 64 ] || vi_die "the GitHub CLI checksum in this installer isn't valid (64 hex characters expected). Tell the VPCC owner. Nothing was changed."
  if [ ! -x "$dir/bin/gh" ]; then
    vi_say "Downloading GitHub CLI $GH_VERSION..."
    mkdir -p "$VPCC_HOME/bin" || vi_die "can't create $VPCC_HOME/bin. Check that you own $VPCC_HOME (e.g. ls -ld '$VPCC_HOME')."
    inc="$(mktemp -d "$VPCC_HOME/bin/.gh-incoming.XXXXXX")" || vi_die "can't create a temp folder in $VPCC_HOME/bin."
    vi_temp "$inc"
    "$VPCC_CURL" -fsSL --max-time 600 -o "$inc/gh.zip" "$url" 2>/dev/null \
      || vi_die "couldn't download GitHub CLI ($url). Check the internet connection (e.g. open https://github.com in Safari), then paste the line again."
    # The checksum is checked BEFORE anything is unpacked.
    got="$("$VPCC_SHASUM" -a 256 "$inc/gh.zip" 2>/dev/null)"; got="${got%% *}"
    [ "$got" = "$VI_GH_SHA" ] || vi_die "the GitHub CLI download doesn't match its checksum (expected ${VI_GH_SHA:0:12}..., got ${got:0:12}...). Nothing was installed. Try again later; if it keeps failing, tell the VPCC owner."
    mkdir "$inc/x" && "$VPCC_DITTO" -x -k "$inc/gh.zip" "$inc/x" 2>/dev/null \
      || vi_die "couldn't unpack the GitHub CLI download. Nothing was installed; paste the line again."
    # (assumed) the official zip holds one folder gh_<v>_macOS_<arch>/ with bin/gh inside.
    found="$(find "$inc/x" -type f -path '*/bin/gh' 2>/dev/null)"
    n="$(printf '%s\n' "$found" | /usr/bin/grep -c .)"
    [ "$n" = 1 ] && [ -n "$found" ] || vi_die "the GitHub CLI download doesn't look as expected (no single bin/gh inside). Tell the VPCC owner. Nothing was installed."
    found="${found%/bin/gh}"
    chmod +x "$found/bin/gh"
    [ -e "$dir" ] && { mv "$dir" "$inc/old" || vi_die "can't replace the broken $dir; remove it (rm -rf '$dir') and paste the line again."; }
    mv "$found" "$dir" || vi_die "can't move GitHub CLI into $dir."
    vi_rm "$inc"
  fi
  # A relative link, swapped in one rename (-h: replace the link itself, not what it points to).
  rm -f "$VPCC_HOME/bin/.gh.new.$$"
  ln -s "gh-$GH_VERSION/bin/gh" "$VPCC_HOME/bin/.gh.new.$$" && mv -fh "$VPCC_HOME/bin/.gh.new.$$" "$VPCC_HOME/bin/gh" \
    || vi_die "can't create the link $VPCC_HOME/bin/gh."
  VI_GH="$VPCC_HOME/bin/gh"
  vi_say "GitHub CLI $GH_VERSION: installed in $dir"
}

# ---- 4. GitHub login + access to the private repo -------------------------------------------------
vi_login() {
  local err who
  if [ "$VI_DRY" = 1 ]; then
    vi_say "[dry-run] would check the GitHub login (gh auth status), log in in the browser if needed (gh auth login --web), run gh auth setup-git and check access to $VPCC_ORG/vpcc"
    return 0
  fi
  if vi_gh auth status --hostname github.com >/dev/null 2>&1; then
    vi_say "GitHub: already logged in"
  else
    vi_say "Logging in to GitHub: your browser opens. Copy the one-time code shown below, paste it in the browser and approve."
    vi_say "Use the GitHub account that is in the $VPCC_ORG organization."
    # gh asks questions on its stdin: give it the terminal, never this script (stdin).
    "$VI_GH" auth login --hostname github.com --git-protocol https --web < "$VPCC_TTY" \
      || vi_die "the GitHub login didn't finish. Paste the line again to retry (it skips the steps already done)."
  fi
  vi_gh auth setup-git --hostname github.com >/dev/null 2>&1 \
    || vi_die "couldn't connect git to the GitHub login (gh auth setup-git failed). Run \`$VI_GH auth setup-git\` to see why, then paste the line again."
  err="$(vi_gh api "repos/$VPCC_ORG/vpcc" --silent 2>&1 >/dev/null)" && { vi_say "GitHub: access to $VPCC_ORG/vpcc ok"; return 0; }
  case "$err" in
    *"HTTP 404"*|*"HTTP 403"*|*"Not Found"*)
      who="$(vi_gh api user --jq .login 2>/dev/null)"
      case "$err" in *SAML*|*SSO*)
        vi_die "your GitHub login ${who:+($who) }must be authorized for the $VPCC_ORG organization's single sign-on. Run \`$VI_GH auth refresh --hostname github.com\`, approve $VPCC_ORG in the browser, then paste the line again." ;;
      esac
      vi_die "you're logged in to GitHub${who:+ as $who}, but that account can't see $VPCC_ORG/vpcc yet: ask your lead for the GitHub org invite${who:+ for $who}, accept it (in the email, or at https://github.com/orgs/$VPCC_ORG/invitation), then paste the line again. Wrong GitHub account? Run \`$VI_GH auth logout\` first." ;;
    *)
      vi_die "couldn't reach $VPCC_ORG/vpcc on GitHub ($(printf '%s' "$err" | /usr/bin/head -n 1)). Check the internet connection and \`$VI_GH auth status\`, then paste the line again." ;;
  esac
}

# ---- 5. the release -----------------------------------------------------------------------------
# vi_get <url> <out>: api.github.com through the gh login (same Accept headers as lib/update.sh
# vu_fetch: raw file for contents, octet-stream for release assets); other https URLs with curl.
vi_get() {
  local url="$1" out="$2" accept
  case "$url" in
    https://api.github.com/*)
      accept="application/vnd.github.raw"
      case "$url" in */releases/assets/*) accept="application/octet-stream" ;; esac
      # A path, not the full URL: gh api takes both (assumed for full URLs), paths for sure.
      vi_gh api -H "Accept: $accept" "${url#https://api.github.com/}" > "$out" 2>/dev/null && return 0 ;;
    https://*)
      "$VPCC_CURL" -fsSL --max-time 600 -o "$out" "$url" 2>/dev/null && return 0 ;;
  esac
  rm -f "$out"; return 1
}

# vi_pick <index file>: prints {version,url,sha256} of the newest "good" release (or nothing).
# The same validity rules and version order as lib/update.sh. A fresh install takes the newest good
# release whatever its age; the 2-day wait of the normal channel (DESIGN 14.2) applies to updates
# of installed Macs only (assumed).
vi_pick() {
  "$VPCC_JQ" -c --arg re "$VI_VERSION_RE" '
    def vk: (split("-")) as $p | ($p[0] | split(".") | map(tonumber)) + [ (if ($p | length) > 1 then 0 else 1 end), ($p[1:] | join("-")) ];
    if (.releases | type) != "array" then error("no releases list") else . end
    | [ .releases[] | select(type == "object")
        | select((.version | type) == "string" and (.version | test($re)))
        | select(.status == "good")
        | select((.sha256 | type) == "string" and (.sha256 | ascii_downcase | test("^[0-9a-f]{64}$")))
        | select((.url | type) == "string" and (.url | test("^https://")))
        | {version, url, sha256: (.sha256 | ascii_downcase)} ]
    | if length == 0 then empty else max_by(.version | vk) end' "$1" 2>/dev/null
}

vi_valid_version() {
  case "$1" in ''|*[!0-9A-Za-z.-]*) return 1 ;; esac
  printf '%s\n' "$1" | /usr/bin/grep -Eq "$VI_VERSION_RE"
}

# vi_tar_safe <tarball>: every entry relative, no ".." part (checked before unpacking).
vi_tar_safe() {
  local list e
  list="$("$VPCC_TAR" -tzf "$1" 2>/dev/null)" || { VI_WHY="the download isn't a readable .tar.gz"; return 1; }
  while IFS= read -r e; do
    case "$e" in
      /*) VI_WHY="it holds an absolute path ($e)"; return 1 ;;
      ..|../*|*/..|*/../*) VI_WHY="it holds a path that leaves its folder ($e)"; return 1 ;;
    esac
  done <<EOF
$list
EOF
  return 0
}

# vi_links_safe <folder>: every symlink inside stays inside (relative, no "..").
vi_links_safe() {
  local l t
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    t="$(readlink "$l")"
    case "$t" in /*|..|../*|*/..|*/../*) VI_WHY="it holds a link that points outside (${l#"$1"/} -> $t)"; return 1 ;; esac
  done <<EOF
$(find "$1" -type l 2>/dev/null)
EOF
  return 0
}

# vi_verify <folder> <version>: a usable release (versions.json .vpcc == version, the installer).
vi_verify() {
  local d="$1" v="$2" have
  [ -f "$d/versions.json" ] || { VI_WHY="versions.json is missing"; return 1; }
  have="$("$VPCC_JQ" -r '.vpcc // empty' "$d/versions.json" 2>/dev/null)" || { VI_WHY="versions.json isn't valid JSON"; return 1; }
  [ "$have" = "$v" ] || { VI_WHY="versions.json says ${have:-nothing}, not $v"; return 1; }
  [ -f "$d/install.sh" ] || { VI_WHY="install.sh is missing"; return 1; }
  [ -f "$d/bin/vpcc" ] || { VI_WHY="bin/vpcc is missing"; return 1; }
  return 0
}

# vi_release: sets VI_V and makes $VPCC_HOME/releases/$VI_V. Nothing is left behind on failure.
vi_release() {
  local idx rj url sha rel inc got root n dest
  rel="$VPCC_HOME/releases"
  if [ "$VI_DRY" = 1 ]; then
    if [ -n "${VPCC_INSTALL_SOURCE:-}" ]; then vi_say "[dry-run] would unpack the local release $VPCC_INSTALL_SOURCE into $rel/<version>/"
    else vi_say "[dry-run] would read the release list of $VPCC_ORG/vpcc, download the newest good release, check its checksum and unpack it into $rel/<version>/"; fi
    vi_say "[dry-run] would point the link $VPCC_HOME/setup at releases/<version>"
    return 0
  fi
  mkdir -p "$rel" || vi_die "can't create $rel. Check that you own $VPCC_HOME (e.g. ls -ld '$VPCC_HOME')."
  inc="$(mktemp -d "$rel/.incoming.XXXXXX")" || vi_die "can't create a temp folder in $rel."
  vi_temp "$inc"
  if [ -n "${VPCC_INSTALL_SOURCE:-}" ]; then
    # A development tarball (tests, a scratch macOS user): no index, no checksum; the latch ran.
    cp "$VPCC_INSTALL_SOURCE" "$inc/release.tgz" 2>/dev/null || vi_die "can't read VPCC_INSTALL_SOURCE ($VPCC_INSTALL_SOURCE)."
    VI_V=""
  else
    vi_say "Reading the release list..."
    vi_get "https://api.github.com/repos/$VPCC_ORG/vpcc/contents/releases.json" "$inc/releases.json" \
      || vi_die "couldn't read the release list of $VPCC_ORG/vpcc. Check the internet connection and \`$VI_GH auth status\`, then paste the line again. Nothing was installed."
    rj="$(vi_pick "$inc/releases.json")"
    [ -n "$rj" ] || vi_die "the release list of $VPCC_ORG/vpcc has no good release to install (or isn't valid). Tell the VPCC owner (releases.json in the vpcc repo). Nothing was installed."
    VI_V="$(printf '%s' "$rj" | "$VPCC_JQ" -r .version)"
    url="$(printf '%s' "$rj" | "$VPCC_JQ" -r .url)"
    sha="$(printf '%s' "$rj" | "$VPCC_JQ" -r .sha256)"
    vi_valid_version "$VI_V" || vi_die "the newest release has an invalid version name. Tell the VPCC owner. Nothing was installed."
    vi_say "Downloading VPCC $VI_V..."
    vi_get "$url" "$inc/release.tgz" \
      || vi_die "couldn't download VPCC $VI_V. Check the internet connection and \`$VI_GH auth status\`, then paste the line again. Nothing was installed."
    got="$("$VPCC_SHASUM" -a 256 "$inc/release.tgz" 2>/dev/null)"; got="${got%% *}"
    [ "$got" = "$sha" ] || vi_die "the VPCC $VI_V download doesn't match its checksum (expected ${sha:0:12}..., got ${got:0:12}...). Nothing was installed. Try again later; if it keeps failing, tell the VPCC owner."
  fi
  vi_tar_safe "$inc/release.tgz" || vi_die "the VPCC download was refused: $VI_WHY. Nothing was installed. Tell the VPCC owner."
  mkdir "$inc/x" && "$VPCC_TAR" -xzf "$inc/release.tgz" -C "$inc/x" 2>/dev/null \
    || vi_die "couldn't unpack the VPCC download. Nothing was installed; paste the line again."
  vi_links_safe "$inc/x" || vi_die "the VPCC download was refused: $VI_WHY. Nothing was installed. Tell the VPCC owner."
  # Flat, or in one top folder (e.g. vpcc-1.0.0/), like lib/update.sh accepts.
  root="$inc/x"
  if [ ! -e "$root/versions.json" ]; then
    n="$(find "$root" -mindepth 1 -maxdepth 1 | /usr/bin/grep -c .)"
    [ "$n" = 1 ] && root="$(find "$root" -mindepth 1 -maxdepth 1 -type d)"
  fi
  if [ -z "$VI_V" ]; then
    VI_V="$("$VPCC_JQ" -r '.vpcc // empty' "$root/versions.json" 2>/dev/null)"
    vi_valid_version "$VI_V" || vi_die "the local release's versions.json has no valid .vpcc version (e.g. \"1.0.0\"). Nothing was installed."
  fi
  [ -n "$root" ] && vi_verify "$root" "$VI_V" || vi_die "the VPCC $VI_V download failed its check: $VI_WHY. Nothing was installed. Tell the VPCC owner."
  dest="$rel/$VI_V"
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    mv "$dest" "$inc/old" || vi_die "can't replace the old $dest; move it away (e.g. mv '$dest' ~/Desktop/) and paste the line again."
  fi
  mv "$root" "$dest" || vi_die "can't move the release into $dest."
  vi_rm "$inc"
  # The link: relative, swapped in one rename (-h: replace the link itself).
  rm -f "$VPCC_HOME/.setup.new.$$"
  ln -s "releases/$VI_V" "$VPCC_HOME/.setup.new.$$" && mv -fh "$VPCC_HOME/.setup.new.$$" "$VPCC_HOME/setup" \
    || vi_die "can't create the link $VPCC_HOME/setup."
  vi_say "VPCC $VI_V: unpacked into $dest"
}

# ---- what is already there -----------------------------------------------------------------------
# Sets VI_INSTALLED to the installed version when $VPCC_HOME/setup is a link to a usable release.
vi_preflight() {
  local s="$VPCC_HOME/setup" t r v
  VI_INSTALLED=""
  if [ -L "$s" ]; then
    t="$(readlink "$s")"
    r="$(vi_resolve "$VPCC_HOME/releases")"
    v="$(vi_resolve "$s")"
    if [ -z "$v" ]; then
      vi_say "Note: $s points to a release that is missing ($t); it will be replaced."
      return 0
    fi
    case "$v" in
      ?*) [ -n "$r" ] && [ "${v#"$r"/}" != "$v" ] || vi_die "$s points to $t, not to a release in $VPCC_HOME/releases (a development link?). Remove the link (rm '$s'; it deletes only the link) and paste the line again." ;;
      *) vi_die "$s points to $t, not to a release in $VPCC_HOME/releases (a development link?). Remove the link (rm '$s'; it deletes only the link) and paste the line again." ;;
    esac
    v="${v#"$r"/}"; VI_WHY="its folder name isn't a version"
    if vi_valid_version "$v" && vi_verify "$VPCC_HOME/setup" "$v"; then VI_INSTALLED="$v"; return 0; fi
    vi_say "Note: $s points to an unusable release ($t: $VI_WHY); a fresh copy will be installed."
    return 0
  fi
  if [ -e "$s" ]; then
    vi_die "$s is a folder (or file), not a link to a release; an older install made it, and it can't be replaced safely. Move it aside, e.g. mv '$s' '$s-old-$(date +%Y%m%d)', then paste the line again."
  fi
  return 0
}

main() {
  local a
  VI_DRY=0; VI_YES=0
  # Ctrl-C or a closed window: remove this run's temp folders (a finished step stays done).
  trap 'printf "\nvpcc-install: stopped; paste the line again to continue.\n" >&2; vi_cleanup; exit 130' INT TERM HUP
  for a in "$@"; do
    case "$a" in
      --dry-run) VI_DRY=1 ;;
      --yes|-y) VI_YES=1 ;;
      -h|--help) vi_usage; return 0 ;;
      *) vi_die "unknown option \"$a\". Options: --dry-run, --yes; e.g. ${VI_LINE% | bash} | bash -s -- --dry-run" ;;
    esac
  done
  [ -n "${BASH_VERSION:-}" ] || { echo "vpcc-install: run it with bash: $VI_LINE" >&2; exit 1; }
  case "$VPCC_ORG" in
    ""|TODO*) vi_die "this copy has no GitHub org set (VPCC_ORG is a placeholder). Use the line your lead sent, e.g. curl -fsSL https://raw.githubusercontent.com/<org>/vpcc-install/main/install.sh | bash" ;;
    *[!A-Za-z0-9-]*) vi_die "the GitHub org name \"$VPCC_ORG\" isn't valid (letters, digits and - only, e.g. VPCC_ORG=VPCC-System)." ;;
  esac
  [ "$("$VPCC_ID" -u 2>/dev/null)" != 0 ] || vi_die "don't run this with sudo or as root: it installs into your own home folder, no admin rights needed. Paste the line again without sudo: $VI_LINE"
  [ -n "${HOME:-}" ] && [ -d "$HOME" ] || vi_die "HOME isn't set to an existing folder. Open a new Terminal window and paste the line again."
  VPCC_HOME="${VPCC_HOME:-$HOME/.vpcc}"
  case "$VPCC_HOME" in /?*) ;; *) vi_die "VPCC_HOME must be an absolute path (it is \"$VPCC_HOME\"), e.g. unset it to use ~/.vpcc." ;; esac
  VPCC_HOME="${VPCC_HOME%/}"
  # Compared resolved, so $HOME/., $HOME/./, a link to the home folder etc. count as the home too.
  [ "$(vi_abs "$VPCC_HOME")" != "$(vi_abs "$HOME")" ] || vi_die "VPCC_HOME can't be your home folder itself (it is \"$VPCC_HOME\"); unset it to use ~/.vpcc."
  case "/$VPCC_HOME/" in */../*) vi_die "VPCC_HOME can't contain a \"..\" part (it is \"$VPCC_HOME\"); unset it to use ~/.vpcc, or give the plain path, e.g. VPCC_HOME=\"\$HOME/.vpcc\"." ;; esac
  vi_latch

  vi_say "VPCC installer (bootstrap)$( [ "$VI_DRY" = 1 ] && printf ' - dry run: nothing is downloaded or changed')"
  vi_say "Installs into $VPCC_HOME. No admin rights needed."
  vi_step "1/6 Checking this Mac"
  vi_check_mac
  vi_preflight
  if [ -n "$VI_INSTALLED" ]; then
    vi_say "VPCC $VI_INSTALLED is already installed; running its installer to check everything."
    vi_say "(For a newer release, run \`vpcc update\` afterwards.)"
  fi
  if [ "$VI_DRY" != 1 ]; then
    vi_say ""
    vi_say "Next: Command Line Tools (if missing), GitHub CLI (if missing), the GitHub login in your browser,"
    vi_say "${VI_INSTALLED:+then the installer of VPCC $VI_INSTALLED.}${VI_INSTALLED:-then the newest VPCC release and its installer.}"
    vi_ask "Continue?" || { vi_say "Stopped; nothing was changed."; return 1; }
  fi

  vi_step "2/6 Command Line Tools"
  vi_clt
  vi_step "3/6 GitHub CLI"
  vi_gh_install
  vi_step "4/6 GitHub login"
  vi_login
  vi_step "5/6 VPCC release"
  if [ -n "$VI_INSTALLED" ]; then
    vi_say "Using the installed VPCC $VI_INSTALLED ($VPCC_HOME/setup)."
  else
    vi_release
  fi
  vi_step "6/6 VPCC installer"
  set --
  [ "$VI_DRY" = 1 ] && set -- "$@" --dry-run
  [ "$VI_YES" = 1 ] && set -- "$@" --yes
  if [ "$VI_DRY" = 1 ] && [ -z "$VI_INSTALLED" ]; then
    vi_say "[dry-run] would run: VPCC_HOME='$VPCC_HOME' VPCC_SETUP='$VPCC_HOME/setup' /bin/bash '$VPCC_HOME/setup/install.sh' $*"
    vi_say "Dry run done: nothing was downloaded or changed."
    return 0
  fi
  [ -f "$VPCC_HOME/setup/install.sh" ] || vi_die "$VPCC_HOME/setup/install.sh is missing. Paste the line again."
  vi_say "Running $VPCC_HOME/setup/install.sh $*"
  export VPCC_HOME VPCC_ORG
  export VPCC_SETUP="$VPCC_HOME/setup"
  [ "$VI_DRY" = 1 ] || export VPCC_GH="$VI_GH"
  export VPCC_BOOTSTRAP=1
  export PATH="$VPCC_HOME/bin:$PATH"
  # The real installer gets the terminal as stdin (stdin here is this script); none -> /dev/null.
  if ( : < "$VPCC_TTY" ) 2>/dev/null; then
    exec /bin/bash "$VPCC_HOME/setup/install.sh" "$@" < "$VPCC_TTY"
  fi
  exec /bin/bash "$VPCC_HOME/setup/install.sh" "$@" < /dev/null
}

{ main "$@"; }
