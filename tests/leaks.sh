#!/bin/bash
# Leak check (DESIGN B.3 (1), (4)), run first by tests/run.sh. This repo is public, so it applies the
# same rules as vpcc's tools/leak-check.sh to every file (any extension, binary ones too: grep -a):
#   - an email whose domain is off the allowlist (example.com, example.invalid,
#     users.noreply.github.com, anthropic.com, or a subdomain of one)
#   - a Keychain item hash ("Claude Code-credentials-<8 hex>") other than the test vector 274c9b72
#   - a real-looking session or conversation id (<8 hex>-<4 hex>- whose first part looks random:
#     5 or more different digits, not a run like 12345678; neutral ones are 11111111-...)
#   - a compressed file under tests/, by name or by its first bytes (its contents can't be checked)
# Exit 1 with the file names (never the value found). B3-install-leaks-weaker: before 1.0.3 this
# check skipped binary files (grep -I) and found compressed files by name only.
# Usage: bash tests/leaks.sh [repo folder]   (default: this repo)
root="${1:-$(cd "$(dirname "$0")/.." && pwd -P)}"
ALLOW='example.com example.invalid users.noreply.github.com anthropic.com'
EMAIL_RE='[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
KEYCHAIN_OK='274c9b72'

# domain_ok <domain>: on the allowlist, or a subdomain of an allowed one (case doesn't matter).
domain_ok() {
  local d a
  d="$(printf '%s' "$1" | tr 'A-Z' 'a-z')"; d="${d%.}"
  for a in $ALLOW; do case "$d" in "$a"|*".$a") return 0 ;; esac; done
  return 1
}
# random_hex <8 hex>: looks random (5+ different digits, and not an ascending run).
random_hex() {
  local h n
  h="$(printf '%s' "$1" | tr 'A-F' 'a-f')"
  case "0123456789abcdef" in *"$h"*) return 1 ;; esac
  n="$(printf '%s' "$h" | fold -w1 | sort -u | wc -l | tr -d ' ')"
  [ "$n" -ge 5 ]
}
# compressed <file>: gzip, zip, bzip2, xz, zstd or 7z by its first bytes.
compressed() {
  case "$(/usr/bin/od -An -tx1 -N6 "$1" 2>/dev/null | tr -d ' \n')" in
    1f8b*|504b0304*|425a68*|fd377a585a00*|28b52ffd*|377abcaf271c*) return 0 ;;
  esac
  return 1
}
# check_file <path relative to root>: prints one line per problem; 1 if any.
check_file() {
  local f="$1" p="$root/$1" e h n=0
  case "$f" in tests/*)
    case "$f" in *.gz|*.tgz|*.zip|*.bz2|*.xz|*.zst|*.7z|*.tar|*.Z|*.dmg|*.jar)
      echo "   $f: compressed file under tests/ (keep fixtures as plain text)"; return 1 ;; esac
    compressed "$p" && { echo "   $f: compressed file under tests/ (keep fixtures as plain text)"; return 1; } ;;
  esac
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    domain_ok "${e##*@}" && continue
    echo "   $f: email outside the allowlist"; n=1; break
  done <<EOF
$(LC_ALL=C /usr/bin/grep -aEo "$EMAIL_RE" "$p" 2>/dev/null)
EOF
  while IFS= read -r h; do
    [ -n "$h" ] || continue
    [ "${h##*-}" = "$KEYCHAIN_OK" ] && continue
    echo "   $f: a Keychain item hash (only the test vector $KEYCHAIN_OK may appear)"; n=1; break
  done <<EOF
$(LC_ALL=C /usr/bin/grep -aEoi 'credentials-[0-9a-f]{8}' "$p" 2>/dev/null)
EOF
  while IFS= read -r h; do
    [ -n "$h" ] || continue
    h="$(printf '%s' "$h" | LC_ALL=C /usr/bin/grep -aEo '[0-9A-Fa-f]{8}-' | head -n 1)"; h="${h%-}"
    random_hex "$h" || continue
    echo "   $f: a real-looking session or conversation id (use a neutral one, e.g. 11111111-0000-4000-8000-000000000001)"; n=1; break
  done <<EOF
$(LC_ALL=C /usr/bin/grep -aEo '(^|[^0-9A-Za-z])[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-|\.\.\.|…)' "$p" 2>/dev/null)
EOF
  return $n
}

rc=0; out=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  f="${f#./}"
  [ -f "$root/$f" ] && [ ! -L "$root/$f" ] || continue
  out="$out$(check_file "$f")" || rc=1
  [ -n "$out" ] && out="$out"$'\n'
done <<EOF
$(cd "$root" && /usr/bin/find . -path ./.git -prune -o -type f -print 2>/dev/null | LC_ALL=C sort)
EOF
if [ $rc -ne 0 ]; then
  echo "leak check: problems (allowed email domains: example.com, example.invalid, users.noreply.github.com, anthropic.com):"
  printf '%s' "$out" | /usr/bin/grep -v '^$'
  exit 1
fi
echo "leak check: ok"
exit 0
