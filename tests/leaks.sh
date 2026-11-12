#!/bin/bash
# Leak check (DESIGN B.3 (1)), run first by tests/run.sh: this repo is public, so no file (any
# extension) may hold an email whose domain is off the allowlist, and tests/ holds no compressed
# files (their contents can't be checked). Exit 1 with the file names (never the full address).
# Usage: bash tests/leaks.sh [repo folder]   (default: this repo)
root="${1:-$(cd "$(dirname "$0")/.." && pwd -P)}"
rc=0
allow='example\.com|example\.invalid|users\.noreply\.github\.com|anthropic\.com'
leaks="$(cd "$root" && /usr/bin/grep -rIEo --exclude-dir=.git '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' . 2>/dev/null |
  /usr/bin/grep -viE "@([A-Za-z0-9-]+\.)*($allow)\$")"
if [ -n "$leaks" ]; then
  echo "leak check: email outside the allowlist (example.com, example.invalid, users.noreply.github.com, anthropic.com):"
  printf '%s\n' "$leaks" | /usr/bin/sed 's/:.*$/: email outside the allowlist/' | /usr/bin/sort -u | /usr/bin/sed 's/^/   /'
  rc=1
fi
packed="$(cd "$root" && /usr/bin/find tests -type f \( -name '*.gz' -o -name '*.tgz' -o -name '*.zip' -o -name '*.tar' -o -name '*.bz2' -o -name '*.xz' -o -name '*.7z' \) 2>/dev/null)"
if [ -n "$packed" ]; then
  echo "leak check: compressed files under tests/:"; printf '%s\n' "$packed" | /usr/bin/sed 's/^/   /'
  rc=1
fi
[ $rc -eq 0 ] && echo "leak check: ok"
exit $rc
