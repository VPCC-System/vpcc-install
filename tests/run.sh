#!/bin/bash
# Runs every tests/test_*.sh. Exit 0 only if all pass. Nothing outside a scratch folder under
# $TMPDIR is touched: every outside command (curl, gh, xcode-select, dscl, ...) is a stub.
cd "$(dirname "$0")" || exit 1
rc=0
for f in test_*.sh; do
  echo "== $f"
  /bin/bash "$f" || rc=1
done
[ $rc -eq 0 ] && echo "ALL PASSED" || echo "SOME TESTS FAILED"
exit $rc
