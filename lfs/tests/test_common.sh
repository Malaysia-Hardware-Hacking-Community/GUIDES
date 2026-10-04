#!/usr/bin/env bash
# Tests for lib/common.sh, including the parts dry-run never touches.
#
# The execution path of run()/runsh() is the thing that most needs testing and
# historically got none: --plan only prints, so a call like
#
#     run "parted -s /dev/vdc mklabel gpt"
#
# -- a single quoted string handed to a varargs function -- prints identically
# to the correct
#
#     run parted -s /dev/vdc mklabel gpt
#
# and fails only in a real run, with ENOENT on a binary that is installed.
# That is exactly the bug this suite exists to prevent recurring.
#
# Run:  bash lfs/tests/test_common.sh
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
LFS_ROOT=$(cd "$HERE/.." && pwd)
M=$(mktemp -d)
export LFS_LOG="$M/log"
export LFS_MOUNTS_FILE="$M/mounts"

source "$LFS_ROOT/installer.sh"

PASS=0; FAIL=0; FAILED_NAMES=""
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); FAILED_NAMES="$FAILED_NAMES $1"; printf '  FAIL %s\n     %s\n' "$1" "$2"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected: $2
     actual:   $3"; fi; }

echo "== 1. run() actually executes its arguments =="
export LFS_DRY_RUN=0
: > "$LFS_LOG"
run touch "$M/executed-by-run"
if [ -f "$M/executed-by-run" ]; then ok "run executes argv, not a single string"
else bad "run executes argv, not a single string" "file was not created"; fi

# The exact regression: a single quoted string must NOT be treated as a
# command line to execute. It should try to exec a binary with that literal
# name and fail -- and critically, it must fail rather than silently succeed.
rm -f "$M/single-string"
if run "touch $M/single-string" 2>/dev/null; then
    # It "succeeded" -- but did it do the right thing? Only if the shell
    # happened to find such a binary, which it will not.
    if [ -f "$M/single-string" ]; then
        bad "single string is not re-parsed" "it was executed as a shell line"
    else
        ok "single string fails loudly instead of guessing"
    fi
else
    # Failed, which is the safe outcome. Confirm nothing was created.
    [ -f "$M/single-string" ] \
        && bad "single string is not re-parsed" "created the file anyway" \
        || ok "single string fails loudly instead of guessing"
fi

echo "== 2. run() propagates failure =="
if run false 2>/dev/null; then bad "run propagates failure" "returned 0 for 'false'"
else ok "run propagates failure"; fi
if run /nonexistent-binary-xyz 2>/dev/null; then bad "run propagates ENOENT" "returned 0"
else ok "run propagates ENOENT"; fi

echo "== 3. run() handles arguments containing spaces =="
D="$M/dir with spaces"
mkdir -p "$D"
if run touch "$D/file.txt" 2>/dev/null && [ -f "$D/file.txt" ]; then
    ok "arguments with spaces are not word-split"
else
    bad "arguments with spaces are not word-split" "file not created at $D/file.txt"
fi

echo "== 4. runsh() actually executes, including shell syntax =="
export LFS_DRY_RUN=0
runsh "echo hello > '$M/runsh-out'"
check "runsh honours redirection" "hello" "$(cat "$M/runsh-out" 2>/dev/null)"
runsh "printf 'a\nb\n' | wc -l > '$M/runsh-pipe'"
check "runsh honours pipes" "2" "$(tr -d ' ' < "$M/runsh-pipe" 2>/dev/null)"
if runsh "exit 7" 2>/dev/null; then bad "runsh propagates failure" "returned 0"
else ok "runsh propagates failure"; fi

echo "== 5. dry-run suppresses execution and logs the command =="
export LFS_DRY_RUN=1
: > "$LFS_LOG"
rm -f "$M/never"
run touch "$M/never"
[ -f "$M/never" ] && bad "dry-run does not execute" "file was created" \
                  || ok "dry-run does not execute"
grep -q "would run: touch $M/never" "$LFS_LOG" \
    && ok "dry-run logs the command" || bad "dry-run logs the command" "not in $LFS_LOG"
runsh "touch $M/never-too"
[ -f "$M/never-too" ] && bad "dry-run runsh does not execute" "file was created" \
                      || ok "dry-run runsh does not execute"

echo "== 6. confirm_irreversible =="
# Always allowed under --plan, which is the point of a plan.
: > "$LFS_LOG"
if confirm_irreversible "erase the disk" >/dev/null 2>&1; then ok "plan always allows the irreversible step"
else bad "plan always allows the irreversible step" "refused under --plan"; fi
grep -q "IRREVERSIBLE" "$LFS_LOG" && ok "plan marks the step irreversible" \
    || bad "plan marks the step irreversible" "not logged"

# A real run must refuse without the acknowledgement. These run in subshells
# because refusing is implemented as die(), which exits -- the right behaviour
# for a bootstrap that must not continue, but it would otherwise take this test
# harness down with it.
export LFS_DRY_RUN=0
# stdin comes from /dev/null on every case below, including the ones that mean
# to exercise the no-terminal refusal. Without it, running this suite from a
# real terminal would make the interactive gate prompt and wait for a keypress
# that no one knows to send.
if ( confirm_irreversible "erase the disk" </dev/null >/dev/null 2>&1 ); then
    bad "real run refuses without acknowledgement" "allowed it"
else ok "real run refuses without acknowledgement"; fi
# ...and proceed once acknowledged.
if LFS_I_UNDERSTAND=yes confirm_irreversible "erase the disk" </dev/null >/dev/null 2>&1; then
    ok "proceeds when acknowledged"
else bad "proceeds when acknowledged" "still refused"; fi
# The acknowledgement must be the literal string "yes", not any truthy value,
# so that a stray "y" or "true" from habit does not wave through a format.
if ( LFS_I_UNDERSTAND=y confirm_irreversible "erase the disk" </dev/null >/dev/null 2>&1 ); then
    bad "requires the literal 'yes'" "accepted 'y'"
else ok "requires the literal 'yes'"; fi
if ( LFS_I_UNDERSTAND=true confirm_irreversible "erase the disk" </dev/null >/dev/null 2>&1 ); then
    bad "requires the literal 'yes'" "accepted 'true'"
else ok "requires the literal 'yes' (not true)"; fi
# With no terminal to ask, the refusal has to name the non-interactive way
# through. A human who ran the documented one-liner through nohup or CI needs
# to be told which flag to use, not just that it was refused.
out=$( confirm_irreversible "erase the disk" </dev/null 2>&1 || true )
case "$out" in
    *--yes*) ok "the no-terminal refusal points at --yes" ;;
    *) bad "the no-terminal refusal points at --yes" "got: $out" ;;
esac

echo "== 6b. on a terminal, the gate asks instead of refusing =="
# The documented usage is a bare `sudo ./installer.sh`, and --yes is described
# as skipping a confirmation. If there is no prompt, the one-liner can never
# finish. These run under a pty (script -qec) so [ -t 0 ] is genuinely true,
# which is the only way to test the branch.
# The reply has to arrive on the pty's own stdin, which is what [ -t 0 ]
# describes, so it is fed by handing it to script rather than by piping it into
# the command (a pipe would make stdin a pipe and take the branch being tested).
pty_run() { script -qec "source '$LFS_ROOT/installer.sh'; $1" /dev/null 2>&1 <<< "$2"; }
out=$( pty_run "LFS_DRY_RUN=0 confirm_irreversible 'erase the disk'; echo RC=\$?" "yes" )
case "$out" in
    *RC=0*) ok "typing yes at the prompt proceeds" ;;
    *) bad "typing yes at the prompt proceeds" "got: $out" ;;
esac
# The prompt must show what is about to happen, so the answer is informed.
case "$out" in
    *"erase the disk"*) ok "the prompt names the change being confirmed" ;;
    *) bad "the prompt names the change being confirmed" "got: $out" ;;
esac
out=$( pty_run "LFS_DRY_RUN=0 confirm_irreversible 'erase the disk'; echo RC=\$?" "no" )
case "$out" in
    *RC=0*) bad "a wrong answer refuses" "allowed it" ;;
    *) ok "a wrong answer refuses" ;;
esac
# The prompt itself is part of what the operator sees, so it has to be worded.
case "$out" in
    *"Type yes to continue"*) ok "the prompt asks for yes explicitly" ;;
    *) bad "the prompt asks for yes explicitly" "got: $out" ;;
esac
out=$( pty_run "LFS_DRY_RUN=1 confirm_irreversible 'erase the disk'; echo RC=\$?" "" )
case "$out" in
    *"IRREVERSIBLE"*) ok "--plan reports the step without prompting" ;;
    *) bad "--plan reports the step without prompting" "got: $out" ;;
esac

echo "== 7. an unwritable log does not break logging =="
# A non-root --plan is legitimate, and the default /var/log path is not
# writable without root. Logging must degrade, not fail.
LFS_LOG=/proc/definitely-not-writable/x.log
export LFS_LOG
out=$(say "this should still reach the terminal" 2>&1)
case "$out" in
    *"this should still reach the terminal"*) ok "message still printed with an unwritable log" ;;
    *) bad "message still printed with an unwritable log" "got: $out" ;;
esac
if run true >/dev/null 2>&1; then ok "run still works with an unwritable log"
else bad "run still works with an unwritable log" "run failed"; fi

echo "== 8. in_list =="
in_list b a b c && ok "in_list finds a member" || bad "in_list finds a member" "not found"
in_list z a b c && bad "in_list rejects a non-member" "matched" || ok "in_list rejects a non-member"
# A needle with a glob character must be compared literally, not as a pattern.
in_list 'x*' 'xy' && bad "in_list is literal, not glob" "glob matched" || ok "in_list is literal, not glob"
# An empty needle must never match -- not even an empty haystack. The callers
# are "is this device/distro in the exempt list" checks, where a vacuous match
# on an empty value would wave a dangerous operation straight through. This is
# pinned deliberately so nobody later "fixes" it into a match.
in_list "" ""        && bad "empty needle does not match an empty list" "matched" \
                        || ok "empty needle does not match an empty list"
in_list "" "a b c"  && bad "empty needle does not match a populated list" "matched" \
                        || ok "empty needle does not match a populated list"

# A list element containing a space is one element, not two. Unquoted $@ word-
# splits it, so a multi-word element could never match and -- worse -- a needle
# could match the wrong fragment of it. Callers pass things like
# "/dev/nvme0n1 p1" and package lists, where one entry can hold a space.
in_list "a b c" "x" "a b c" "y" \
    && ok "in_list matches an element containing a space" \
    || bad "in_list matches an element containing a space" "no match"
in_list "a b" "ab c" \
    && bad "in_list does not match a fragment of a split element" "matched" \
    || ok "in_list does not match a fragment of a split element"
# A glob character in an element must not expand against the filesystem either.
in_list '*.tar.xz' 'a' '*.tar.xz' \
    && ok "in_list matches a glob-looking element literally" \
    || bad "in_list matches a glob-looking element literally" "no match"
in_list 'x*' 'x' 'x1' \
    && bad "in_list does not expand a glob in an element" "expanded and matched" \
    || ok "in_list does not expand a glob in an element"

# ---------------------------------------------------------------------------
# lfs_job_count: the -j cap.
#
# The function reads MemAvailable out of /proc/meminfo, so the arithmetic is
# exercised against fixtures: the already-sourced function is dumped with
# `declare -f` (the real body, not a re-implementation of it) and its meminfo
# path repointed at a temp file. nproc is stubbed with a shell function, which
# bash resolves ahead of PATH.
#
# Worth testing rather than trusting: the failure this guards is a cap that
# quietly stops applying, and -j64 on a 4-core box cannot be caught by running
# the build on a machine that happens to have enough RAM.
# ---------------------------------------------------------------------------
JC_SRC=$(declare -f lfs_job_count 2>/dev/null)
NCPU=4
if [ -z "$JC_SRC" ]; then
    bad "lfs_job_count is defined" "not found in the sourced installer"
else
    ok "lfs_job_count is defined"
    jc_jobs() {   # jc_jobs <MiB> -> the -j the function would choose
        local mb="$1"
        printf 'MemTotal: %s kB\nMemAvailable: %s kB\n' \
               $((mb*1024)) $((mb*1024)) > "$M/meminfo"
        sed "s|/proc/meminfo|$M/meminfo|" <<< "$JC_SRC" > "$M/jc.sh"
        bash -c "nproc() { printf '%s' $NCPU; }; . $M/jc.sh; lfs_job_count"
    }
    # 1.5 GB per job, so 2 GiB cannot support two. This is the case that used
    # to OOM: the VM has cores to spare and no memory to spend on them.
    check "a 2 GiB host gets -j1, not -j4" 1 "$(jc_jobs 2048)"
    check "a 4 GiB host gets -j2" 2 "$(jc_jobs 4096)"
    check "a 6 GiB host reaches the CPU count" 4 "$(jc_jobs 6144)"
    # The nproc ceiling. Without it, 64 GiB of RAM on a 4-core box hands make
    # -j42 and the build thrashes instead of using the memory.
    check "a large-RAM host is still capped at the CPU count" 4 "$(jc_jobs 65536)"
    # -j0 is a make error; "this VM has 1 GiB" must not become one.
    check "a tiny host still gets -j1, never -j0" 1 "$(jc_jobs 256)"
    # LFS_JOBS is the escape hatch for a cgroup limit /proc/meminfo cannot see
    # (a shared host, a systemd unit with MemoryMax=).
    printf 'MemTotal: 8388608 kB\nMemAvailable: 8388608 kB\n' > "$M/meminfo"
    sed "s|/proc/meminfo|$M/meminfo|" <<< "$JC_SRC" > "$M/jc.sh"
    check "LFS_JOBS overrides the computed value" 2 \
          "$(bash -c ". $M/jc.sh; LFS_JOBS=2 lfs_job_count")"
    # No /proc/meminfo at all must fall back to the CPU count, not to -j0.
    sed 's|/proc/meminfo|/nonexistent/meminfo|' <<< "$JC_SRC" > "$M/jc2.sh"
    got=$( bash -c "nproc() { printf '%s' $NCPU; }; . $M/jc2.sh; lfs_job_count" )
    case "$got" in
        ''|*[!0-9]*) bad "missing /proc/meminfo falls back to a CPU count" "got '$got'" ;;
        *)          ok "missing /proc/meminfo falls back to a CPU count ($got)" ;;
    esac
fi

rm -rf "$M"
echo
echo "================================"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then printf 'failing:%s\n' "$FAILED_NAMES"; exit 1; fi
printf 'ALL COMMON TESTS PASSED\n'
exit 0
