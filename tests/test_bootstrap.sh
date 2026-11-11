#!/bin/bash
# Tests for install.sh (the bootstrap). Every run is fed to bash on stdin, like `curl ... | bash`,
# with HOME (it has a space in it) and every path inside a scratch folder, and every outside
# command replaced by a stub that records its arguments. The real home, Keychain, network,
# GitHub and Command Line Tools are never touched.
set -u
HERE="$(cd "$(dirname "$0")" && pwd -P)"
BOOT="$HERE/../install.sh"
VPCC_REPO="${VPCC_REPO:-$HOME/Desktop/vpcc}"   # read only: the fake release is built from it
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/vpcc-boot-test.XXXXXX")"
trap 'chmod -R u+w "$SANDBOX" 2>/dev/null; rm -rf "$SANDBOX"' EXIT
PASS=0; FAIL=0; TNAME=""
t() { TNAME="$1"; }
ok() { PASS=$((PASS+1)); printf '  ok   %s\n' "$TNAME"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s: %s\n' "$TNAME" "$*"; }
eq() { if [ "$1" = "$2" ]; then ok; else bad "expected [$2], got [$1]"; fi; }
has() { case "$1" in *"$2"*) ok ;; *) bad "expected to contain [$2], got [$1]" ;; esac; }
hasnt() { case "$1" in *"$2"*) bad "must not contain [$2], got [$1]" ;; *) ok ;; esac; }
yes_() { if "$@"; then ok; else bad "expected true: $*"; fi; }
no_() { if "$@"; then bad "expected false: $*"; else ok; fi; }

[ -x /usr/bin/gh ] && { echo "a gh in /usr/bin would hide the 'gh missing' case; stopping"; exit 1; }
[ -d "$VPCC_REPO/lib" ] || { echo "the vpcc repo isn't at $VPCC_REPO (set VPCC_REPO)"; exit 1; }

S="$SANDBOX/stubs"; G="$SANDBOX/ghdir"; FIX="$SANDBOX/fix"; B="$SANDBOX/build"
mkdir -p "$S" "$G" "$FIX" "$B"

# ---- stubs (they write to $VPCC_TEST_LOG, which the bootstrap passes on untouched) --------------
cat > "$S/uname" <<'EOF'
#!/bin/bash
echo "$*" >> "$VPCC_TEST_LOG/uname"
case "$1" in -s) echo "${STUB_OS:-Darwin}" ;; -m) echo "${STUB_ARCH:-arm64}" ;; esac
EOF
cat > "$S/sw_vers" <<'EOF'
#!/bin/bash
echo "${STUB_MACOS:-26.5.2}"
EOF
cat > "$S/dscl" <<'EOF'
#!/bin/bash
echo "$*" >> "$VPCC_TEST_LOG/dscl"
[ "${STUB_DSCL_FAIL:-}" = 1 ] && exit 56
# STUB_DSCL_USER: only that user has STUB_REAL_HOME; every other name gets /var/empty.
if [ -n "${STUB_DSCL_USER:-}" ] && [ "$3" != "/Users/$STUB_DSCL_USER" ]; then echo "NFSHomeDirectory: /var/empty"; exit 0; fi
echo "NFSHomeDirectory: ${STUB_REAL_HOME:-/Users/someone-else}"
EOF
cat > "$S/id" <<'EOF'
#!/bin/bash
case "$1" in -u) echo "${STUB_UID:-501}" ;; -un) echo testuser ;; esac
EOF
# xcode-select: -p fails until it has been asked STUB_CLT_AFTER times (or never: "never").
cat > "$S/xcode-select" <<'EOF'
#!/bin/bash
echo "$*" >> "$VPCC_TEST_LOG/xcode-select"
case "$1" in
  -p) n=$(grep -c '^-p$' "$VPCC_TEST_LOG/xcode-select")
      [ "${STUB_CLT_AFTER:-0}" = never ] && exit 2
      [ "$n" -gt "${STUB_CLT_AFTER:-0}" ] && { echo /Library/Developer/CommandLineTools; exit 0; }
      exit 2 ;;
  --install) exit 0 ;;
esac
EOF
cat > "$S/sleep" <<'EOF'
#!/bin/bash
echo "$*" >> "$VPCC_TEST_LOG/sleep"
EOF
cat > "$S/curl" <<'EOF'
#!/bin/bash
echo "$*" >> "$VPCC_TEST_LOG/curl"
out=""; url=""
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift ;; https://*) url="$1" ;; esac; shift; done
case "$url" in
  https://github.com/cli/cli/releases/download/*) cp "$VPCC_TEST_FIX/gh.zip" "$out" ;;
  *) exit 22 ;;
esac
EOF
for tool in shasum tar ditto; do
  printf '#!/bin/bash\necho "$*" >> "$VPCC_TEST_LOG/%s"\nexec /usr/bin/%s "$@"\n' "$tool" "$tool" > "$S/$tool"
done
# gh: logged in once `auth login` ran; serves the fake release list and tarball.
cat > "$G/gh" <<'EOF'
#!/bin/bash
echo "$*" >> "$VPCC_TEST_LOG/gh"
echo "${1:-} ${2:-}: nu=${GH_NO_UPDATE_NOTIFIER:-} pd=${GH_PROMPT_DISABLED:-}" >> "$VPCC_TEST_LOG/gh_env"
case "$*" in
  "auth status"*) [ -f "$VPCC_TEST_LOG/gh_logged" ] ;;
  "auth login"*) IFS= read -r l; echo "stdin=[$l]" > "$VPCC_TEST_LOG/gh_stdin"; touch "$VPCC_TEST_LOG/gh_logged"; echo "! First copy your one-time code: ABCD-1234" ;;
  "auth setup-git"*) exit 0 ;;
  "api user"*) echo robin-gh ;;
  "api repos/testorg/vpcc --silent")
     [ -f "$VPCC_TEST_FIX/noaccess" ] && { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
     [ -f "$VPCC_TEST_FIX/offline" ] && { echo "error connecting to api.github.com" >&2; exit 1; }
     exit 0 ;;
  "api -H Accept: application/vnd.github.raw repos/testorg/vpcc/contents/releases.json") cat "$VPCC_TEST_FIX/releases.json" ;;
  "api -H Accept: application/octet-stream repos/testorg/vpcc/releases/assets/"*) a="$*"; cat "$VPCC_TEST_FIX/asset-${a##*/}.tgz" ;;
  *) echo "gh stub: unexpected: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$S"/* "$G/gh"

# ---- fixtures -----------------------------------------------------------------------------------
GHV=2.103.3
mkdir -p "$B/gh_${GHV}_macOS_arm64/bin"
cp "$G/gh" "$B/gh_${GHV}_macOS_arm64/bin/gh"
(cd "$B" && /usr/bin/ditto -c -k --keepParent "gh_${GHV}_macOS_arm64" "$FIX/gh.zip")
GHSHA="$(/usr/bin/shasum -a 256 "$FIX/gh.zip" | cut -d' ' -f1)"

# mkrel <asset id> <version> [hook] [tar args...]: a release made from the real vpcc tree, with
# versions.json .vpcc set and install.sh replaced by a stub that records how it was started.
mkrel() {
  local id="$1" v="$2" hook="${3:-}" d="$B/vpcc-$2"; shift 3 2>/dev/null || shift $#
  rm -rf "$d"; mkdir -p "$d"
  cp -R "$VPCC_REPO/bin" "$VPCC_REPO/lib" "$VPCC_REPO/base" "$VPCC_REPO/config.sh" "$VPCC_REPO/toolkits.json" "$d/"
  /usr/bin/jq --arg v "$v" '.vpcc = $v' "$VPCC_REPO/versions.json" > "$d/versions.json"
  cat > "$d/install.sh" <<'EOF'
#!/bin/bash
{ echo "args=[$*]"; echo "VPCC_HOME=$VPCC_HOME"; echo "VPCC_SETUP=$VPCC_SETUP"; echo "VPCC_GH=${VPCC_GH:-}"
  echo "VPCC_ORG=$VPCC_ORG"; echo "VPCC_BOOTSTRAP=${VPCC_BOOTSTRAP:-}"; echo "GH_NO_UPDATE_NOTIFIER=${GH_NO_UPDATE_NOTIFIER:-}"; echo "real=$(cd "$VPCC_SETUP" && pwd -P)"
  echo "me=$0"; echo "PATH=$PATH"; IFS= read -r l; echo "stdin=[$l]"; } > "$VPCC_TEST_LOG/installer"
EOF
  if [ -n "$hook" ]; then (cd "$d" && eval "$hook"); fi
  (cd "$B" && /usr/bin/tar -czf "$FIX/asset-$id.tgz" "$@" "vpcc-$v")
}
sha() { /usr/bin/shasum -a 256 "$FIX/asset-$1.tgz" | cut -d' ' -f1; }
rel() { /usr/bin/jq -nc --arg v "$1" --arg s "$2" --arg u "https://api.github.com/repos/testorg/vpcc/releases/assets/$3" --arg h "${4:-$(sha "$3")}" \
  '{version: $v, date: "2026-11-08T09:00:00Z", status: $s, notes: "n", url: $u, sha256: $h}'; }
index() { printf '%s\n' "$@" | /usr/bin/jq -s '{releases: .}' > "$FIX/releases.json"; }

mkrel 1 1.0.0
mkrel 2 0.9.0
mkrel 3 1.1.0
mkrel 4 1.2.0-rc1
good_index() { index "$(rel 1.0.0 good 1)" "$(rel 0.9.0 good 2)" "$(rel 1.1.0 withdrawn 3)" "$(rel 1.2.0-rc1 held 4)"; }
good_index

# ---- one run ------------------------------------------------------------------------------------
N=0
# fresh: a new HOME (with a space), log folder and tty answer file ("y").
fresh() {
  N=$((N+1))
  H="$SANDBOX/run $N/home dir"; L="$SANDBOX/run $N/log"; TTYF="$SANDBOX/run $N/tty"
  mkdir -p "$H" "$L"; printf 'y\n' > "$TTYF"
  V="$H/.vpcc"
  rm -f "$FIX/noaccess" "$FIX/offline"
}
# boot [args...]: `cat install.sh | bash -s -- args` with every outside command stubbed.
# Extra env (e.g. STUB_CLT_AFTER=3) goes in E=(...) set by the caller. Sets OUT, RC.
boot() {
  OUT="$(/usr/bin/env -i HOME="$H" USER=testuser TMPDIR="${TMPDIR:-/tmp}" PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    VPCC_TEST_LOG="$L" VPCC_TEST_FIX="$FIX" VPCC_BOOTSTRAP_TEST=1 VPCC_ORG=testorg VPCC_TTY="$TTYF" \
    VPCC_UNAME="$S/uname" VPCC_SW_VERS="$S/sw_vers" VPCC_DSCL="$S/dscl" VPCC_ID="$S/id" \
    VPCC_XCODE_SELECT="$S/xcode-select" VPCC_SLEEP="$S/sleep" VPCC_CURL="$S/curl" \
    VPCC_SHASUM="$S/shasum" VPCC_TAR="$S/tar" VPCC_DITTO="$S/ditto" GH_SHA256_ARM64="$GHSHA" \
    ${E[@]+"${E[@]}"} /bin/bash -s -- "$@" < "${BOOT_SRC:-$BOOT}" 2>&1)"; RC=$?
}
E=()
lg() { cat "$L/$1" 2>/dev/null; }
calls() { if [ -f "$L/$1" ]; then /usr/bin/grep -c . "$L/$1"; else echo 0; fi; }
tree() { (cd "$H" && find . -print0 | xargs -0 stat -f '%N %p %z %m %Y' | sort); }
leftovers() { find "$H" -name '.incoming.*' -o -name '.gh-incoming.*' -o -name '.setup.new.*' -o -name '.gh.new.*' 2>/dev/null; }

echo "-- fresh install: CLT missing then appears, gh downloaded, login, release, exec"
fresh; E=(STUB_CLT_AFTER=4)
boot
t "exit 0"; eq "$RC" 0
t "HOME has a space"; has "$H" " "
t "CLT install asked once"; eq "$(/usr/bin/grep -c -- '--install' "$L/xcode-select")" 1
t "click Install told"; has "$OUT" 'click "Install"'
t "polled every 20 s"; eq "$(sort -u "$L/sleep")" 20
t "polled until CLT appeared (5th check, 3 waits)"; eq "$(calls sleep)" 3
t "gh zip from the pinned official URL"; has "$(lg curl)" "https://github.com/cli/cli/releases/download/v$GHV/gh_${GHV}_macOS_arm64.zip"
t "sha checked before unzip"; yes_ [ -f "$L/shasum" ]
t "ditto -x -k used"; has "$(lg ditto)" "-x -k"
t "gh installed in bin/gh-<v>"; yes_ [ -x "$V/bin/gh-$GHV/bin/gh" ]
t "bin/gh is a relative link"; eq "$(readlink "$V/bin/gh")" "gh-$GHV/bin/gh"
t "login with web + https"; has "$(lg gh)" "auth login --hostname github.com --git-protocol https --web"
t "setup-git ran"; has "$(lg gh)" "auth setup-git"
t "gh login reads the terminal, not stdin"; eq "$(lg gh_stdin)" "stdin=[y]"
t "installer reads the terminal, not stdin"; has "$(lg installer)" "stdin=[y]"
t "repo access checked"; has "$(lg gh)" "api repos/testorg/vpcc --silent"
t "release list read raw"; has "$(lg gh)" "api -H Accept: application/vnd.github.raw repos/testorg/vpcc/contents/releases.json"
t "newest GOOD release downloaded (1.0.0, not withdrawn 1.1.0 / held rc)"; has "$(lg gh)" "application/octet-stream repos/testorg/vpcc/releases/assets/1"
t "unpacked into releases/1.0.0"; yes_ [ -f "$V/releases/1.0.0/versions.json" ]
t "setup is a relative link"; eq "$(readlink "$V/setup")" "releases/1.0.0"
t "no temp leftovers"; eq "$(leftovers)" ""
t "installer ran"; yes_ [ -f "$L/installer" ]
t "installer: no args"; has "$(lg installer)" "args=[]"
t "installer: VPCC_HOME"; has "$(lg installer)" "VPCC_HOME=$V"
t "installer: VPCC_SETUP is the stable link"; has "$(lg installer)" "VPCC_SETUP=$V/setup"
t "installer: started via the link"; has "$(lg installer)" "me=$V/setup/install.sh"
t "installer: link resolves to the release"; has "$(lg installer)" "real=$(cd "$V/releases/1.0.0" && pwd -P)"
t "installer: VPCC_GH"; has "$(lg installer)" "VPCC_GH=$V/bin/gh"
t "installer: VPCC_ORG + VPCC_BOOTSTRAP"; has "$(lg installer)" "VPCC_ORG=testorg"
t "installer: ~/.vpcc/bin on PATH"; has "$(lg installer)" "PATH=$V/bin:"
# Finding 13 of TESTS #66: gh's "new release available" notice is switched off for every gh call;
# prompts are off for the non-interactive ones only (`gh auth login` must stay interactive).
t "gh: update notice off on every call"; eq "$(/usr/bin/grep -vc 'nu=1 ' "$L/gh_env")/$(calls gh_env)" "0/$(calls gh)"
t "gh auth login: prompts left on"; eq "$(/usr/bin/grep '^auth login:' "$L/gh_env")" "auth login: nu=1 pd="
t "gh auth status: prompts off"; has "$(lg gh_env)" "auth status: nu=1 pd=1"
t "gh auth setup-git: prompts off"; has "$(lg gh_env)" "auth setup-git: nu=1 pd=1"
t "gh api: prompts off on every call"; eq "$(/usr/bin/grep '^api ' "$L/gh_env" | /usr/bin/grep -vc 'pd=1$')" 0
t "  (api was called)"; yes_ /usr/bin/grep -q '^api ' "$L/gh_env"
t "installer: gh update notice off"; has "$(lg installer)" "GH_NO_UPDATE_NOTIFIER=1"
t "dscl asked for the real home"; has "$(lg dscl)" ". -read /Users/testuser NFSHomeDirectory"
t "the unpacked tree is the vpcc repo"; yes_ [ -f "$V/releases/1.0.0/bin/vpcc" ]

echo "-- --yes and --dry-run pass through"
fresh; E=(); printf 'n\n' > "$TTYF"
boot --yes
t "--yes: no question asked"; hasnt "$OUT" "Continue?"
t "--yes: installed"; eq "$RC" 0
t "--yes passed to the installer"; has "$(lg installer)" "args=[--yes]"

echo "-- re-run with setup already linked"
boot --yes
t "already installed message"; has "$OUT" "VPCC 1.0.0 is already installed; running its installer to check everything"
t "release list not read again"; eq "$(/usr/bin/grep -c 'contents/releases.json' "$L/gh")" 1
t "installer ran again"; has "$(lg installer)" "args=[--yes]"
t "link unchanged"; eq "$(readlink "$V/setup")" "releases/1.0.0"
boot --dry-run
t "dry-run on an installed Mac runs its installer with --dry-run"; has "$(lg installer)" "args=[--dry-run]"

echo "-- --dry-run on a fresh Mac changes nothing"
fresh; E=(STUB_CLT_AFTER=never)
before="$(tree)"
boot --dry-run --yes
t "exit 0"; eq "$RC" 0
t "tree unchanged"; eq "$(tree)" "$before"
t "no .vpcc"; no_ [ -e "$V" ]
t "says dry run"; has "$OUT" "Dry run done: nothing was downloaded or changed."
t "would install CLT"; has "$OUT" "[dry-run] would run \`xcode-select --install\`"
t "no CLT install"; hasnt "$(lg xcode-select)" "--install"
t "no download"; eq "$(calls curl)$(calls gh)$(calls ditto)$(calls tar)" 0000
t "no installer"; no_ [ -f "$L/installer" ]
t "shows the installer call"; has "$OUT" "install.sh' --dry-run --yes"

echo "-- gh zip checksum mismatch stops before unzip"
fresh; E=(GH_SHA256_ARM64=0000000000000000000000000000000000000000000000000000000000000000)
boot --yes
t "fails"; eq "$RC" 1
t "message"; has "$OUT" "vpcc-install: the GitHub CLI download doesn't match its checksum"
t "no unzip"; eq "$(calls ditto)" 0
t "no gh installed"; no_ [ -e "$V/bin/gh" ]
t "no gh folder"; no_ [ -e "$V/bin/gh-$GHV" ]
t "no leftovers"; eq "$(leftovers)" ""
t "no release"; no_ [ -e "$V/releases" ]

echo "-- gh checksum still a placeholder: no download"
fresh; E=(GH_SHA256_ARM64=TODO-verify)
boot --yes
t "fails"; eq "$RC" 1
t "message"; has "$OUT" "no checksum for GitHub CLI $GHV (arm64) yet"
t "no download"; eq "$(calls curl)" 0

echo "-- gh already on PATH: no download"
fresh; E=(VPCC_GH="$G/gh")
boot --yes
t "installed"; eq "$RC" 0
t "no gh download"; eq "$(calls curl)" 0
t "no bin/gh"; no_ [ -e "$V/bin/gh" ]
t "installer gets that gh"; has "$(lg installer)" "VPCC_GH=$G/gh"

echo "-- already logged in to GitHub: no login"
fresh; E=(VPCC_GH="$G/gh"); touch "$L/gh_logged"
boot --yes
t "no auth login"; hasnt "$(lg gh)" "auth login"
t "setup-git still runs"; has "$(lg gh)" "auth setup-git"

echo "-- release checksum mismatch stops before unpack"
fresh; E=(VPCC_GH="$G/gh")
index "$(rel 1.0.0 good 1 1111111111111111111111111111111111111111111111111111111111111111)"
boot --yes
t "fails"; eq "$RC" 1
t "message"; has "$OUT" "vpcc-install: the VPCC 1.0.0 download doesn't match its checksum"
t "no tar"; eq "$(calls tar)" 0
t "no release"; no_ [ -e "$V/releases/1.0.0" ]
t "no setup link"; no_ [ -L "$V/setup" ]
t "no leftovers"; eq "$(leftovers)" ""
t "no installer"; no_ [ -f "$L/installer" ]

echo "-- a tarball with ../evil is refused and leaves nothing"
mkrel 5 1.0.0 'echo evil > evil.txt' -s ',^vpcc-1.0.0/evil.txt$,../evil.txt,'
fresh; E=(VPCC_GH="$G/gh"); index "$(rel 1.0.0 good 5)"
boot --yes
t "fails"; eq "$RC" 1
t "message"; has "$OUT" "leaves its folder (../evil.txt)"
t "never extracted"; hasnt "$(lg tar)" "-xzf"
t "no evil file"; eq "$(find "$SANDBOX/run $N" -name evil.txt)" ""
t "no release, no link"; no_ [ -e "$V/releases/1.0.0" ] || [ -L "$V/setup" ]
t "no leftovers"; eq "$(leftovers)" ""

echo "-- a tarball with an absolute member is refused"
mkdir -p "$B/abs"; echo evil > "$B/abs/evil-abs.txt"
mkrel 6 1.0.0 '' -P "$B/abs/evil-abs.txt"
rm -rf "$B/abs"
fresh; E=(VPCC_GH="$G/gh"); index "$(rel 1.0.0 good 6)"
boot --yes
t "fails"; eq "$RC" 1
t "message"; has "$OUT" "holds an absolute path"
t "not written at the absolute path"; no_ [ -e "$B/abs/evil-abs.txt" ]
t "no release, no leftovers"; eq "$(ls -A "$V/releases" 2>/dev/null)$(leftovers)" ""

echo "-- a tarball with a link pointing outside is refused"
mkrel 7 1.0.0 'ln -s /etc etc-link'
fresh; E=(VPCC_GH="$G/gh"); index "$(rel 1.0.0 good 7)"
boot --yes
t "fails"; eq "$RC" 1
t "message"; has "$OUT" "link that points outside"
t "nothing left"; eq "$(ls -A "$V/releases" 2>/dev/null)$(leftovers)" ""

echo "-- a release whose versions.json says another version is refused"
mkrel 8 0.8.0
fresh; E=(VPCC_GH="$G/gh"); index "$(rel 1.0.0 good 8)"
boot --yes
t "fails"; eq "$RC" 1
t "message"; has "$OUT" "versions.json says 0.8.0, not 1.0.0"
t "nothing left"; eq "$(ls -A "$V/releases" 2>/dev/null)$(leftovers)" ""

echo "-- a release list with no good release"
fresh; E=(VPCC_GH="$G/gh"); index "$(rel 1.1.0 withdrawn 3)" "$(rel 1.2.0-rc1 held 4)"
boot --yes
t "fails with the fix"; has "$OUT" "has no good release to install"
t "nothing left"; eq "$(ls -A "$V/releases" 2>/dev/null)$(leftovers)" ""
echo "not json" > "$FIX/releases.json"
boot --yes
t "invalid list: fails"; has "$OUT" "has no good release to install (or isn't valid)"
good_index

echo "-- placeholder org refused"
fresh; E=(VPCC_ORG=TODO-github-org)
boot --yes
t "fails"; eq "$RC" 1
t "message"; has "$OUT" "vpcc-install: this copy has no GitHub org set"
t "nothing created"; no_ [ -e "$V" ]
t "nothing called"; eq "$(calls uname)$(calls dscl)$(calls curl)" 000
# The shipped default is the company org (owner, 11-11). Checked in the file, not by an unstubbed
# run: once the gh checksums are filled in, a real run would download gh.
fresh; E=()
t "the shipped default is VPCC-System"; has "$(/usr/bin/grep '^VPCC_ORG=' "$BOOT")" 'VPCC_ORG="${VPCC_ORG:-VPCC-System}"'
t "the paste line names VPCC-System"; has "$(/usr/bin/grep '^VI_LINE=' "$BOOT")" "githubusercontent.com/VPCC-System/vpcc-install/main/install.sh"
E=(VPCC_ORG='bad/org')
boot --yes
t "bad org name"; has "$OUT" "isn't valid"

echo "-- not in the org yet"
fresh; E=(VPCC_GH="$G/gh"); touch "$FIX/noaccess"
boot --yes
t "fails"; eq "$RC" 1
t "message"; has "$OUT" "ask your lead for the GitHub org invite"
t "names the GitHub login"; has "$OUT" "logged in to GitHub as robin-gh"
t "no release"; no_ [ -e "$V/releases" ]
rm -f "$FIX/noaccess"; touch "$FIX/offline"
boot --yes
t "offline: other message"; has "$OUT" "couldn't reach testorg/vpcc on GitHub (error connecting"
rm -f "$FIX/offline"

echo "-- setup is a plain folder: refused"
fresh; E=(VPCC_GH="$G/gh"); mkdir -p "$V/setup"; echo keep > "$V/setup/x"
boot --yes
t "fails"; eq "$RC" 1
t "message"; has "$OUT" "is a folder (or file), not a link to a release"
t "gives the mv fix"; has "$OUT" "mv '$V/setup' '$V/setup-old-"
t "folder untouched"; eq "$(cat "$V/setup/x")" keep
t "nothing downloaded"; eq "$(calls gh)$(calls curl)" 00

echo "-- setup links elsewhere: refused; dangling link: replaced"
fresh; E=(VPCC_GH="$G/gh"); mkdir -p "$V" "$SANDBOX/run $N/dev"; ln -s "$SANDBOX/run $N/dev" "$V/setup"
boot --yes
t "elsewhere: refused"; has "$OUT" "not to a release in $V/releases"
t "elsewhere: link kept"; eq "$(readlink "$V/setup")" "$SANDBOX/run $N/dev"
rm "$V/setup"; ln -s releases/0.5.0 "$V/setup"
boot --yes
t "dangling: noted"; has "$OUT" "points to a release that is missing"
t "dangling: replaced"; eq "$(readlink "$V/setup")" "releases/1.0.0"
t "dangling: installer ran"; yes_ [ -f "$L/installer" ]

echo "-- a cut-off download runs nothing"
size="$(wc -c < "$BOOT" | tr -d ' ')"
last="$(tail -n 1 "$BOOT")"
lastpos=$((size - ${#last} - 1))
cuts="$((size / 10)) $((size / 4)) $((size / 2)) $((size * 3 / 4)) $((size * 9 / 10)) $((size - 300)) $((lastpos - 1))"
# Every cut inside the last line (e.g. one that ends right after "main", dropping "$@").
c=$lastpos; while [ "$c" -lt "$((size - 1))" ]; do cuts="$cuts $c"; c=$((c + 1)); done
allquiet=1; detail=""
for c in $cuts; do
  fresh; E=(VPCC_GH="$G/gh")
  head -c "$c" "$BOOT" > "$SANDBOX/cut.sh"
  BOOT_SRC="$SANDBOX/cut.sh" boot --yes
  if [ -e "$V" ] || [ -n "$(ls -A "$L")" ]; then allquiet=0; detail="$detail cut=$c($(ls "$L" | tr '\n' ' '))"; fi
done
t "no cut ran anything (cuts: $cuts)"; eq "$allquiet$detail" 1
t "the last line is the only call"; eq "$last" '{ main "$@"; }'
# The full file minus only its final newline still runs (curl may drop nothing but that).
fresh; E=(VPCC_GH="$G/gh"); head -c "$((size - 1))" "$BOOT" > "$SANDBOX/cut.sh"
BOOT_SRC="$SANDBOX/cut.sh" boot --dry-run --yes
t "the whole script without its last newline still runs"; has "$OUT" "Dry run done"

echo "-- safety latch: the real home"
fresh; E=(STUB_REAL_HOME="$H")
boot --yes
t "fires"; eq "$RC" 1
t "message"; has "$OUT" "vpcc-install: safety latch: HOME is your real home"
t "nothing created"; no_ [ -e "$V" ]
t "nothing else called"; eq "$(calls uname)$(calls curl)$(calls xcode-select)" 000
fresh; E=(STUB_REAL_HOME="$H/../home dir/")
boot --yes
t "fires on a differently spelled real home"; has "$OUT" "safety latch"
fresh; E=(STUB_DSCL_FAIL=1)
boot --yes
t "fires when the real home can't be read"; has "$OUT" "couldn't read the real home folder"
t "  nothing created"; no_ [ -e "$V" ]
fresh; E=(STUB_REAL_HOME="$H" VPCC_INSTALL_I_KNOW=1)
boot --dry-run
t "VPCC_INSTALL_I_KNOW=1 overrides"; eq "$RC" 0
fresh; E=(STUB_REAL_HOME="$H" VPCC_BOOTSTRAP_TEST= VPCC_INSTALL_SOURCE="$FIX/asset-1.tgz" VPCC_GH="$G/gh")
boot --yes
t "fires for a local source too"; has "$OUT" "safety latch"
fresh; E=(STUB_REAL_HOME="$H" VPCC_BOOTSTRAP_TEST= VPCC_GH="$G/gh")
boot --dry-run
t "a normal run (no dev source, not a test) on the real home is allowed"; eq "$RC" 0
# A VPCC_HOME left in the environment (e.g. VPCC_HOME=~/.vpcc after a real install) points into
# the real home while HOME is a scratch folder.
fresh; REAL="$SANDBOX/run $N/realhome"; mkdir -p "$REAL"
E=(STUB_REAL_HOME="$REAL" VPCC_HOME="$REAL/.vpcc" VPCC_GH="$G/gh")
boot --yes
t "VPCC_HOME in the real home: fires"; eq "$RC" 1
t "  message"; has "$OUT" "safety latch: VPCC_HOME ($REAL/.vpcc) is inside your real home"
t "  nothing created"; eq "$(ls -A "$REAL")" ""
fresh; REAL="$SANDBOX/run $N/realhome"; mkdir -p "$REAL"
E=(STUB_REAL_HOME="$REAL" VPCC_HOME="$REAL/.vpcc" VPCC_BOOTSTRAP_TEST= VPCC_INSTALL_SOURCE="$FIX/asset-1.tgz" VPCC_GH="$G/gh")
boot --yes
t "VPCC_HOME in the real home, local source: fires"; has "$OUT" "safety latch: VPCC_HOME"
t "  nothing created"; eq "$(ls -A "$REAL")" ""
fresh; REAL="$SANDBOX/run $N/realhome"; mkdir -p "$REAL"
E=(STUB_REAL_HOME="$REAL/./" VPCC_HOME="$REAL" VPCC_GH="$G/gh")
boot --yes
t "VPCC_HOME is the real home itself (spelled differently): fires"; has "$OUT" "safety latch: VPCC_HOME"
# A scratch HOME inside the real home (e.g. ~/vpcc-test) stays allowed.
fresh; E=(STUB_REAL_HOME="$SANDBOX/run $N" VPCC_GH="$G/gh")
boot --yes
t "scratch HOME inside the real home, VPCC_HOME inside it: allowed"; eq "$RC" 0
t "  installed there"; eq "$(readlink "$V/setup")" "releases/1.0.0"
# The latch asks the user database about the real user (id -un), not about $USER.
fresh; E=(STUB_REAL_HOME="$H" STUB_DSCL_USER=testuser USER=someone VPCC_GH="$G/gh")
boot --yes
t "USER=someone else: still fires"; eq "$RC" 1
t "  message"; has "$OUT" "safety latch: HOME is your real home"
t "  nothing created"; no_ [ -e "$V" ]
t "  asked about the id -un user"; has "$(lg dscl)" "/Users/testuser"

echo "-- VPCC_HOME spelled as the home folder itself is refused"
for spell in "/." "/./" "/../home dir"; do
  fresh; E=(VPCC_HOME="$H$spell" VPCC_GH="$G/gh")
  boot --yes
  t "VPCC_HOME=\$HOME$spell refused"; has "$OUT" "VPCC_HOME can't be your home folder itself"
  t "  nothing created"; eq "$(ls -A "$H")" ""
done
fresh; ln -s "$H" "$SANDBOX/run $N/home-link"; E=(VPCC_HOME="$SANDBOX/run $N/home-link" VPCC_GH="$G/gh")
boot --yes
t "VPCC_HOME = a link to the home folder refused"; has "$OUT" "VPCC_HOME can't be your home folder itself"
fresh; E=(VPCC_HOME="$H/x/../.vpcc" VPCC_GH="$G/gh")
boot --yes
t "VPCC_HOME with a .. part refused"; has "$OUT" "VPCC_HOME can't contain"

echo "-- read-only folders in a release: temp folders are still removed"
mkrel 10 1.0.1 'chmod 555 lib'
fresh; E=(VPCC_GH="$G/gh"); index "$(rel 1.0.0 good 10)"
boot --yes; boot --yes
t "bad release refused"; has "$OUT" "versions.json says 1.0.1, not 1.0.0"
t "  no rm errors"; hasnt "$OUT" "Directory not empty"
t "  no temp leftovers after two runs"; eq "$(leftovers)" ""
mkrel 11 1.0.0 'chmod 555 lib'
fresh; E=(VPCC_GH="$G/gh"); index "$(rel 1.0.0 good 11)"
boot --yes
t "read-only release installs"; eq "$RC" 0
rm -f "$V/releases/1.0.0/install.sh" 2>/dev/null || { chmod u+w "$V/releases/1.0.0"; rm -f "$V/releases/1.0.0/install.sh"; }
boot --yes
t "  broken copy replaced"; eq "$RC" 0
t "  no rm errors"; hasnt "$OUT" "Directory not empty"
t "  old copy and temp folders removed"; eq "$(leftovers)" ""
t "  only the release left"; eq "$(ls -A "$V/releases")" "1.0.0"
chmod -R u+w "$SANDBOX/run $N" "$B" 2>/dev/null
good_index

echo "-- local release (VPCC_INSTALL_SOURCE) in a scratch home"
fresh; E=(VPCC_INSTALL_SOURCE="$FIX/asset-2.tgz" VPCC_GH="$G/gh")
boot --yes
t "installed"; eq "$RC" 0
t "version from versions.json"; eq "$(readlink "$V/setup")" "releases/0.9.0"
t "no release list read"; hasnt "$(lg gh)" "releases.json"
t "installer ran"; has "$(lg installer)" "VPCC_SETUP=$V/setup"

echo "-- questions come from the terminal, never stdin"
fresh; E=(VPCC_GH="$G/gh"); printf 'n\n' > "$TTYF"
boot
t "no: stops"; eq "$RC" 1
t "no: message"; has "$OUT" "Stopped; nothing was changed."
t "no: nothing created"; no_ [ -e "$V" ]
fresh; E=(VPCC_GH="$G/gh" VPCC_TTY="$SANDBOX/no-such-tty")
boot
t "no terminal: fails with the --yes fix"; has "$OUT" "bash -s -- --yes"
t "no terminal: nothing created"; no_ [ -e "$V" ]

echo "-- this Mac"
fresh; E=(STUB_MACOS=14.6)
boot --yes
t "macOS 14 refused"; has "$OUT" "VPCC needs macOS 15 or newer; this Mac has macOS 14.6"
t "  nothing created"; no_ [ -e "$V" ]
fresh; E=(STUB_OS=Linux)
boot --yes
t "not macOS refused"; has "$OUT" "VPCC runs on macOS only"
fresh; E=(STUB_ARCH=ppc)
boot --yes
t "unknown arch refused"; has "$OUT" "processor type (ppc) isn't supported"
fresh; E=(STUB_ARCH=x86_64 GH_SHA256_AMD64=TODO-verify)
boot --yes
t "Intel: amd64 gh asked for"; has "$OUT" "no checksum for GitHub CLI $GHV (amd64)"
fresh; E=(STUB_UID=0)
boot --yes
t "root refused"; has "$OUT" "don't run this with sudo"
t "  nothing created"; no_ [ -e "$V" ]
fresh; E=()
boot --frobnicate
t "unknown option"; has "$OUT" 'unknown option "--frobnicate"'
fresh; E=(VPCC_HOME=relative/path)
boot --yes
t "relative VPCC_HOME refused"; has "$OUT" "VPCC_HOME must be an absolute path"

echo "-- a release built by the vpcc repo's tools/make-release.sh is accepted"
if [ -f "$VPCC_REPO/tools/make-release.sh" ]; then
  MR="$SANDBOX/mr-repo"; mkdir -p "$MR"
  (cd "$VPCC_REPO" && /usr/bin/tar -cf - --exclude .git --exclude dist .) | (cd "$MR" && /usr/bin/tar -xf -)
  /usr/bin/jq '.vpcc = "1.3.0"' "$VPCC_REPO/versions.json" > "$MR/versions.json"
  cp "$B/vpcc-1.0.0/install.sh" "$MR/install.sh"
  MROUT="$(/usr/bin/env -i HOME="$SANDBOX" PATH=/usr/bin:/bin:/usr/sbin:/sbin TMPDIR="${TMPDIR:-/tmp}" VPCC_ORG=testorg \
    /bin/bash "$MR/tools/make-release.sh" --repo "$MR" --out "$SANDBOX/mr-out" --notes "test" \
    --url https://api.github.com/repos/testorg/vpcc/releases/assets/9 2>&1)"
  cp "$SANDBOX/mr-out/vpcc-1.3.0.tar.gz" "$FIX/asset-9.tgz" 2>/dev/null
  t "make-release built it"; yes_ [ -f "$FIX/asset-9.tgz" ]
  printf '%s\n' "$MROUT" | /usr/bin/sed -n '/^releases.json entry:/,/^}/p' | /usr/bin/sed 1d | /usr/bin/jq -s '{releases: .}' > "$FIX/releases.json"
  fresh; E=(VPCC_GH="$G/gh")
  boot --yes
  t "installed"; eq "$RC" 0
  t "linked"; eq "$(readlink "$V/setup")" "releases/1.3.0"
  t "installer ran"; has "$(lg installer)" "VPCC_SETUP=$V/setup"
  good_index
else
  echo "  (skipped: no tools/make-release.sh in $VPCC_REPO)"
fi

echo "-- CLT never appears: gives up with the fix"
fresh; E=(STUB_CLT_AFTER=never VPCC_CLT_MAX=200 VPCC_GH="$G/gh")
boot --yes
t "fails"; eq "$RC" 1
t "message"; has "$OUT" "still aren't installed after 3 minutes"
t "10 waits of 20 s"; eq "$(calls sleep)" 10
t "a dot per minute"; has "$OUT" "..."
t "nothing else done"; eq "$(calls gh)" 0

echo "-- README (findings 11 and 12 of TESTS #66)"
RD="$(cat "$HERE/../README.md")"
LINE="$(/usr/bin/sed -n "s/^VI_LINE='\(.*\)'\$/\1/p" "$BOOT")"
t "README: the install line is the bootstrap's own (https)"; has "$RD" "$LINE"
t "  (that line is https)"; has "$LINE" "curl -fsSL https://"
t "README: copy the line exactly, with why"; has "$RD" 'Copy the line exactly (copy and paste, don'"'"'t retype it): it must start with `https://`'
# Observed 11-11 (finding 12 of TESTS #66): a retyped http:// line works (redirect), so the why is "not protected".
t "  why matches what happens: http works but isn't protected"; has "$RD" "that first request isn't protected, so it can be read or changed on the way"
t "  no claim that http fetches something else"; hasnt "$RD" 'fetches something else'
t "README: same window: exec zsh -l"; has "$RD" 'Run `exec zsh -l` there first, or open a new Terminal window.'

printf '%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
