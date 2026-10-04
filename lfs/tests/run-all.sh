#!/usr/bin/env bash
# Run every unit suite. No root, no network, no VM.
#
#   bash lfs/tests/run-all.sh
#
# Exits non-zero if any suite fails. The live VM test is deliberately NOT
# here: it destroys disks, and it lives in the sandbox tools.
#
# test_single.sh is last on purpose. It is the suite about the single-file
# arrangement itself, and the only one that reads installer.sh as text rather
# than by sourcing it, so it should have the last word.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
RC=0
FAILED=""

TOTAL=0
declare -A COUNTED=()
for t in test_common.sh test_detect.sh test_pkgmgr.sh test_target.sh \
         test_boot.sh test_build.sh test_single.sh; do
    printf '\n########## %s ##########\n' "$t"
    # Count from each suite's own summary line rather than assuming, so the
    # total printed below and the number README.md quotes come from the same
    # place the suites report.
    OUT=$( bash "$HERE/$t" )
    printf '%s\n' "$OUT"
    if [ -n "$OUT" ]; then
        n=$( printf '%s' "$OUT" | sed -n 's/^passed: *\([0-9][0-9]*\).*/\1/p' | tail -1 )
        if [ -n "$n" ]; then
            TOTAL=$(( TOTAL + n ))
            COUNTED[${t%.sh}]=$n
        fi
    fi
    if printf '%s' "$OUT" | grep -q 'failed: 0'; then
        :
    else
        RC=1
        FAILED="$FAILED $t"
    fi
done

# The per-suite table and the total in README.md are hand-maintained and have
# drifted before. Check them here, where every suite has just run, rather than
# trusting a number nobody recomputes.
printf '\n########## README.md counts ##########\n'
ROOT=$(cd "$HERE/.." && pwd)
DRIFT=""
for t in test_common.sh test_detect.sh test_pkgmgr.sh test_target.sh \
         test_boot.sh test_build.sh test_single.sh; do
    suite=${t%.sh}
    claimed=$( sed -n "s/^| \`$t\` | \([0-9]*\) |.*/\1/p" "$ROOT/README.md" )
    # COUNTED[$suite] came from the run above; do not run the suite a second time.
    n=${COUNTED[$suite]:-none}
    if [ "$claimed" != "$n" ]; then
        DRIFT="$DRIFT $suite(README=$claimed actual=$n)"
    fi
done
claimed_total=$( sed -n 's/^| `tests\/` | \([0-9]*\) checks.*/\1/p' "$ROOT/README.md" )
if [ -n "$DRIFT" ]; then
    printf '  FAIL  README.md per-suite counts are stale:%s\n' "$DRIFT"
    RC=1
else
    printf '  ok    README.md per-suite counts are current\n'
fi
if [ "$claimed_total" = "$TOTAL" ]; then
    printf '  ok    README.md total matches the suites (%s)\n' "$TOTAL"
else
    printf '  FAIL  README.md total says %s, suites sum to %s\n' "$claimed_total" "$TOTAL"
    RC=1
fi

printf '\n##################################\n'
if [ "$RC" -eq 0 ]; then
    printf 'ALL SUITES PASSED (%s checks)\n' "$TOTAL"
else
    printf 'FAILING SUITES:%s\n' "$FAILED"
fi
exit "$RC"
