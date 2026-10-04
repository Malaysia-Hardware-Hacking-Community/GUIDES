#!/usr/bin/env bash
# Tests for the single-file arrangement itself.
#
# Every other suite asks "does this function behave correctly". This one asks
# "did the merge into one file keep working", and it covers exactly the three
# things the merge had to rewrite:
#
#   1. the include-once guards. In one file a leaked guard is a trap, not
#      redundancy: `return 0` partway through a sourced file means the SECOND
#      source silently loses every function after it. That happened.
#   2. the in-chroot task dispatch. The tasks used to be six separate files
#      invoked by path; they are now functions reached by `bash
#      /root/installer.sh --internal <name>` across a chroot boundary, and a
#      renamed task is now a "no such file" four hours into a build.
#   3. the env -i hand-off into the chroot. The chroot is started with an empty
#      environment, so every variable the bootable stage needs has to be named
#      explicitly. Drop one and grub-install quietly guesses the wrong disk.
#
# Run:  bash lfs/tests/test_single.sh
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
LFS_ROOT=$(cd "$HERE/.." && pwd)
INSTALLER="$LFS_ROOT/installer.sh"
M=$(mktemp -d)
trap 'rm -rf "$M"' EXIT

# This suite has no `set -e`, because it asserts on commands that are SUPPOSED
# to fail. The cost is that an unknown command is just a nonzero status that
# nobody looks at: a check calling a helper this file does not define printed
# "command not found" and the suite still reported 100% -- a false pass, on a
# check that was never run at all. Verified by getting it wrong.
#
# Only 127 is fatal. Blanket errexit would abort on the checks that are meant
# to fail -- `grep` matching nothing is the PASS case for "no stale
# references" -- but 127 is unambiguous: it is what the shell returns for a
# command it could not find, and nothing in this suite expects that.
_lfs_unknown_cmd() {
    if [ "$?" = 127 ]; then
        printf '\ntest_single.sh: command not found at line %s: %s\n' "$1" "$2" >&2
        exit 1
    fi
    return 0
}
trap '_lfs_unknown_cmd "$LINENO" "$BASH_COMMAND"' ERR

export LFS_LOG="$M/log"
export LFS_DRY_RUN=1

PASS=0; FAIL=0; FAILED_NAMES=""
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); FAILED_NAMES="$FAILED_NAMES $1"; printf '  FAIL %s\n     expected: %s\n     actual:   %s\n' "$1" "${2-}" "${3-}"; }
check() { if [ "${2-}" = "${3-}" ]; then ok "$1"; else bad "$1" "${2-}" "${3-}"; fi; }

echo "== 1. the installer is one runnable file =="
[ -f "$INSTALLER" ] && ok "installer.sh exists" || { bad "installer.sh exists" "missing"; exit 1; }
[ -x "$INSTALLER" ] && ok "installer.sh is executable" \
                    || bad "installer.sh is executable" "not +x; the documented `curl -O && sudo ./installer.sh` would fail"
head -1 "$INSTALLER" | grep -q '^#!.*bash$' \
    && ok "has a bash shebang" \
    || bad "has a bash shebang" "got: $(head -1 "$INSTALLER")"

echo
echo "== 2. sourcing defines everything and runs nothing =="
# The whole test strategy depends on this: the suites source the installer to
# reach real functions, so a source that acted like a run would be a disaster.
out=$( LFS_LOG="$M/src.log" bash -c 'source "$1"; echo DONE' _ "$INSTALLER" 2>&1 )
check "a bare source produces no output" "DONE" "$out"

# ...and the guard regression specifically: source it twice in one shell.
#
# Unsetting every function between the two sources is the part that matters.
# Without it the test proves nothing: the first source leaves the functions
# defined, so a second source that returns early still looks complete. Asking
# the second source to actually re-define them is what an include-once guard
# gets wrong, and it is exactly what a stale guard would break.
out=$( bash -c '
    source "$1" || exit 1
    for f in $(declare -F | awk "{print \$3}"); do unset -f "$f"; done
    declare -F | awk "{print \$3}" | grep -q . && { echo "NOT-CLEARED"; exit 4; }
    source "$1" || exit 2
    for f in lfs_main lfs_build lfs_internal pkgmgr_table task_bootable \
             target_select lfs_supported_pkgmgr lfs_enter_chroot; do
        declare -F "$f" >/dev/null || { echo "LOST:$f"; exit 3; }
    done
    echo SECOND-SOURCE-OK' _ "$INSTALLER" 2>&1 )
check "a second source re-defines every function" "SECOND-SOURCE-OK" "$out"

# Sourcing must not depend on hidden globals left by an earlier source. Set
# every installer-internal guard name to 1 first: with a stale guard still in
# the file this returns early and defines nothing, which is the failure in its
# purest form.
out=$( bash -c '
    export _LFS_COMMON_SH=1 _LFS_DETECT_SH=1 _LFS_DEPS_SH=1 _LFS_TARGET_SH=1 _LFS_BOOT_SH=1
    source "$1" || exit 1
    declare -F lfs_main >/dev/null || { echo "GUARDED"; exit 1; }
    echo GUARDS-IMMUNE' _ "$INSTALLER" 2>&1 )
check "pre-set guard names cannot suppress the definitions" "GUARDS-IMMUNE" "$out"

# A leaked include-once guard is exactly a `return 0` in the middle of the
# file, so assert on the text too -- this catches it at the source rather than
# only when a human happens to source twice.
if grep -qE '^_LFS_[A-Z_]+_SH=1$' "$INSTALLER"; then
    bad "no include-once guard survived the merge" \
        "$(grep -nE '^_LFS_[A-Z_]+_SH=1$' "$INSTALLER" | tr '\n' ' ')"
else
    ok "no include-once guard survived the merge"
fi

echo
echo "== 3. the file references nothing that is not shipped =="
# The point of a single file is that there is nothing else to fetch or keep in
# sync. A stale comment or error message naming pkgmgr/foo.conf or lib/target.sh
# sends a reader looking for a file that does not exist, so the merge asserts on
# its own output and this test holds it to that.
stale=$( grep -oE 'pkgmgr/[a-z-]*\.conf|lib/(common|detect|deps|target|boot)\.sh|lfs-bootstrap\.sh|bootstrap\.sh|build-lfs\.sh|enter-chroot\.sh|make-bootable\.sh|chroot-prep\.sh|fetch-sources\.sh|kernel-config\.sh|strip-ch8\.sh|system-config\.sh' "$INSTALLER" | sort -u )
if [ -n "$stale" ]; then
    bad "no references to the removed split files" "$(printf '%s' "$stale" | tr '\n' ' ')"
else
    ok "no references to the removed split files"
fi

echo
echo "== 4. the argument surface =="
check "--help exits 0" "0" "$(bash "$INSTALLER" --help >/dev/null 2>&1; echo $?)"
check "--help mentions takeover as the default" "yes" \
      "$(bash "$INSTALLER" --help 2>/dev/null | grep -q 'takeover (default)' && echo yes || echo no)"
check "an unknown option exits 2" "2" "$(bash "$INSTALLER" --nonsense >/dev/null 2>&1; echo $?)"
check "--mode refuses an unknown mode" "1" \
      "$(bash "$INSTALLER" --mode bogus --plan >/dev/null 2>&1; echo $?)"
check "--firmware refuses an unknown mode" "1" \
      "$(bash "$INSTALLER" --firmware bogus --plan >/dev/null 2>&1; echo $?)"

echo
echo "== 5. this host is refused before any target is chosen =="
# The plan below is a real --plan invocation on the machine running the tests.
# It must die on the refusal alone: no disk listing, no package line, nothing
# that would mean a target had already been picked. A refusal that came after
# target selection would be one `set -e` change away from being useless.
# shellcheck disable=SC1090  # INSTALLER path is built at runtime
if [ "$(. "$INSTALLER" >/dev/null 2>&1; printf '%s' "$LFS_REFUSED_DISTROS")" = "omarchy" ] \
   && [ "$(. /etc/os-release >/dev/null 2>&1; printf '%s' "${ID:-}")" = "omarchy" ]; then
    msg=$(bash "$INSTALLER" --plan 2>&1)
    case "$msg" in
        *omarchy*) ok "a real --plan run refuses omarchy by name" ;;
        *) bad "a real --plan run refuses omarchy by name" "got: $(printf '%s' "$msg" | head -3)" ;;
    esac
    # The refusal must come before the target is chosen: "using target=" would
    # mean the plan picked a disk on a host that must never be touched.
    case "$msg" in
        *"using target="*) bad "the refusal precedes target selection" "a target was chosen first" ;;
        *) ok "the refusal precedes target selection" ;;
    esac
    case "$msg" in
        *"packages:"*) bad "the refusal precedes dependency installation" "a package line was printed" ;;
        *) ok "the refusal precedes dependency installation" ;;
    esac
else
    printf '  skip (not running on omarchy; refusal covered in test_detect.sh)\n'
fi

echo
echo "== 6. every in-chroot task is reachable by the name the build uses =="
# The build calls these across a chroot boundary by name. A task that exists as
# a function but is missing from the dispatch is a build that dies at stage 06
# with "unknown internal task", after downloading and unpacking everything.
#
# Deliberately never CALL lfs_internal with a real task name here: these tasks
# run inside a chroot and write /etc/passwd, /etc/group and /boot on whatever
# root they find. Invoking one from a test suite would rewrite the host's
# account files. Existence is checked with declare -F, and only the unknown-name
# refusal is executed, which touches nothing.
# shellcheck source=/dev/null
source "$INSTALLER"

for task in chroot-prep kernel strip-ch8 sysconfig bootable; do
    if declare -F "task_${task//-/_}" >/dev/null; then
        ok "task_$task is defined"
    else
        bad "task_$task is defined" "no such function"
    fi
done

# The dispatch itself: every name in the case list must reach a real function.
# Read the case labels out of the dispatch and check each one, so a task added
# to the function list but forgotten in the case list is caught too.
# Newlines flattened to spaces: the case-glob below matches a single line, and
# a newline-separated list silently matches nothing -- which is a green test for
# a broken dispatch.
dispatched=$( sed -n '/^lfs_internal()/,/^}/p' "$INSTALLER" \
              | sed -n 's/^        \([a-z0-9-]\+\)) .*/\1/p' | tr '\n' ' ' )
if [ -n "$(printf '%s' "$dispatched" | tr -d ' ')" ]; then
    ok "the internal dispatch has case labels"
else
    bad "the internal dispatch has case labels" "none parsed"
fi
for task in $dispatched; do
    fn="task_${task//-/_}"
    declare -F "$fn" >/dev/null \
        && ok "dispatch '$task' reaches $fn" \
        || bad "dispatch '$task' reaches $fn" "no such function"
done

# ...and the build must only call names the dispatch knows.
called=$( grep -oE 'installer\.sh --internal [a-z0-9-]+' "$INSTALLER" | awk '{print $NF}' | tr '\n' ' ' )
if [ -n "$(printf '%s' "$called" | tr -d ' ')" ]; then
    ok "the build calls --internal tasks"
else
    bad "the build calls --internal tasks" "none found in the build stages"
fi
for task in $called; do
    case " $dispatched " in
        *" $task "*) ok "the build's --internal $task is dispatched" ;;
        *) bad "the build's --internal $task is dispatched" "dispatched: $dispatched" ;;
    esac
done
# A dispatched task nothing calls is dead weight that will rot; a called task
# nothing dispatches is the failure above. Only report the first direction,
# which is cheap to state and impossible to get wrong silently.
for task in $dispatched; do
    case " $called " in
        *" $task "*) : ;;
        *) printf '  note  dispatched task '\''%s'\'' is not called by any stage\n' "$task" ;;
    esac
done

check "an unknown internal task is refused" "2" "$(lfs_internal no-such-task >/dev/null 2>&1; echo $?)"
check "an unknown internal task exits 2 as a process" "2" \
      "$(bash "$INSTALLER" --internal no-such-task >/dev/null 2>&1; echo $?)"

echo
echo "== 7. the build hands the target's identity into the chroot =="
# lfs_enter_chroot starts the chroot with `env -i`, so anything it needs has to
# be named on that command line. Stub chroot and read the argument vector the
# chroot would really have been started with.
#
# Note what is NOT done here: the stub does not run `env` to capture the
# resulting environment, because a fake chroot never applies the -i list and
# would report its own inherited environment instead. Checking the inherited
# environment would have passed on HOME and PATH for the wrong reason and
# reported an empty LFS_BOOT_DISK as fine. The argument vector is the thing
# lfs_enter_chroot is actually responsible for.
LFS="$M/target"
LFS_ROOT_DEV=/dev/vdd1
LFS_ROOT_UUID=deadbeef-0000-0000-0000-000000000000
LFS_ROOT_PARTUUID=cafe-babe-0000-0000-0000-000000000000
LFS_BOOT_DISK=/dev/vdd
LFS_ESP_MOUNT=/boot/efi
LFS_FIRMWARE=bios
export LFS LFS_ROOT_DEV LFS_ROOT_UUID LFS_ROOT_PARTUUID LFS_BOOT_DISK \
       LFS_ESP_MOUNT LFS_FIRMWARE

STUB="$M/stub"
mkdir -p "$STUB" "$LFS"
cat > "$STUB/chroot" <<'STUBEOF'
#!/usr/bin/env bash
printf '%s\0' "$@" > "$STUBDIR/argv"
exit 0
STUBEOF
cat > "$STUB/mount"      <<'STUBEOF'
#!/usr/bin/env bash
exit 0
STUBEOF
cat > "$STUB/mountpoint" <<'STUBEOF'
#!/usr/bin/env bash
exit 1
STUBEOF
chmod +x "$STUB"/*

STUBDIR="$M" PATH="$STUB:$PATH" lfs_enter_chroot 'echo hello' >/dev/null 2>&1

if [ -f "$M/argv" ]; then
    ok "the chroot is entered through a stubbed chroot binary"
    # The identity must be present AND correct. env -i passes an empty string
    # through perfectly happily, and an empty LFS_BOOT_DISK is exactly the
    # silent-grub-wrong-disk bug this guards.
    for pair in "HOME=/root" \
                "LFS_ROOT_DEV=$LFS_ROOT_DEV" \
                "LFS_ROOT_UUID=$LFS_ROOT_UUID" \
                "LFS_ROOT_PARTUUID=$LFS_ROOT_PARTUUID" \
                "LFS_BOOT_DISK=$LFS_BOOT_DISK" \
                "LFS_ESP_MOUNT=$LFS_ESP_MOUNT" \
                "LFS_FIRMWARE=$LFS_FIRMWARE"; do
        var=${pair%%=*}
        if tr '\0' '\n' < "$M/argv" | grep -qxF "$pair"; then
            ok "the chroot is started with $var"
        else
            bad "the chroot is started with $var" \
                "got: $(tr '\0' '\n' < "$M/argv" | grep -E "^$var=" || echo '(absent)')"
        fi
    done
    # PATH and MAKEFLAGS are what make bash -e -c and the build's parallelism
    # work at all; an empty PATH is a chroot that cannot run anything.
    for var in PATH MAKEFLAGS; do
        if tr '\0' '\n' < "$M/argv" | grep -qE "^$var=.+"; then
            ok "the chroot gets a non-empty $var"
        else
            bad "the chroot gets a non-empty $var" \
                "got: $(tr '\0' '\n' < "$M/argv" | grep -E "^$var=" || echo '(absent)')"
        fi
    done
    # env -i really is there, and the command really is last.
    if tr '\0' '\n' < "$M/argv" | grep -qx -- '-i'; then
        ok "the chroot environment is built with env -i"
    else
        bad "the chroot environment is built with env -i" "no -i in the argument vector"
    fi
    if tr '\0' '\n' < "$M/argv" | grep -qxF 'echo hello'; then
        ok "the command argument reaches the chroot"
    else
        bad "the command argument reaches the chroot" \
            "argv: $(tr '\0' '\n' < "$M/argv" | tr '\n' ' ')"
    fi
else
    bad "the chroot is entered at all" "the stub chroot never ran; PATH stubbing failed"
fi

echo
echo "== 8. a failed build returns instead of exiting the caller =="
# lfs_build is called from lfs_main, which still has to unmount the ESP and the
# target afterwards. A bare `exit` inside the build would strand both mounted.
# The one failure reachable without a real filesystem is a stage list that came
# out empty, which is also what a botched book extraction looks like from here.
# (The guard is checked indirectly below: `${#_s[@]}` on the string "STAGE5" is
# 6 forever, so only an indirect expansion can catch this at all.)
out=$( ( STAGE5=(); LFS_LOG="$M/build.log" lfs_build --mount "$LFS" ) 2>&1 )
rc=$?
check "lfs_build returns 1 when a stage list is empty" "1" "$rc"
case "$out" in
    *"is empty"*) ok "and says why" ;;
    *) bad "and says why" "got: $out" ;;
esac
check "lfs_build --stage bogus returns 2" "2" \
      "$(LFS_LOG="$M/build.log" lfs_build --mount "$LFS" --stage bogus >/dev/null 2>&1; echo $?)"
check "lfs_build --nonsense returns 2" "2" \
      "$(LFS_LOG="$M/build.log" lfs_build --nonsense >/dev/null 2>&1; echo $?)"

# A resume has to be able to re-run a stage that already got most of the way
# through. Book 8.85's cleanup deletes the `tester` user, so an unguarded
# `userdel -r tester` makes the ch8 tail fail on its last command the second
# time -- the stage a resume exists to retry can then never be retried.
STRIP=$( sed -n '/^task_strip_ch8()/,/^}/p' "$INSTALLER" )
check "the ch8 tail guards userdel for re-entry" "1" \
      "$(printf '%s\n' "$STRIP" | grep -c 'if id tester >/dev/null 2>&1; then')"
if printf '%s\n' "$STRIP" | grep -qE '^\s*userdel -r tester\s*$'; then
    ok "userdel only runs when tester exists"
else
    bad "userdel only runs when tester exists" "found an unguarded userdel"
fi
# Guarding the re-entrancy must not turn a genuine userdel failure into a
# warning, so the call stays inside the `then` and keeps its own exit status.
check "userdel is not made non-fatal" "0" \
      "$(printf '%s\n' "$STRIP" | grep -cE '^\s*userdel -r tester\s*\|\|')"

# The fstab is keyed on the root UUID so the disk boots wherever it enumerates.
# That reasoning is silently undone unless the kernel command line is too:
# /etc/grub.d/10_linux emits root=UUID= only when /dev/disk/by-uuid/$UUID
# exists, and no udev runs in the build chroot to create it. Observed on a real
# build: a correct UUID fstab next to `linux ... root=/dev/vdb2`.
BOOTABLE=$( sed -n '/^task_bootable()/,/^}/p' "$INSTALLER" )
# The rewrite is what makes the kernel command line agree with the fstab, so it
# has to name the actual root device, not a literal that resolves to nothing.
check "grub.cfg root= is rewritten to PARTUUID, not UUID" "1" \
      "$(printf '%s\n' "$BOOTABLE" | grep -c 's|root=/dev/\$rootpart.b|root=PARTUUID=\$LFS_ROOT_PARTUUID|g')"
# root=UUID= looks right and is what the fstab uses, but this kernel panics with
# "VFS: Cannot open root device" on it even when the UUID is the real one, so a
# regression to the UUID spelling is a boot failure rather than a style change.
check "no root=UUID= is written into grub.cfg" "0" \
      "$(printf '%s\n' "$BOOTABLE" | grep -c 'root=UUID=\$LFS_ROOT_UUID|g')"


check "the rewrite strips the /dev/ prefix before matching" "1" \
      "$(printf '%s\n' "$BOOTABLE" | grep -c 'rootpart="\${LFS_ROOT_DEV#/dev/}"')"
# Without this the build ships a config that boots today and dies the day the
# disk is moved, which is the whole point of the rewrite.
check "a leftover device-path or UUID root= fails the build" "1" \
      "$(printf '%s\n' "$BOOTABLE" | grep -cF "root=(/dev/|UUID=)")"
check "the leftover-root guard actually returns non-zero" "1" \
      "$(printf '%s\n' "$BOOTABLE" | sed -n '/does not boot by PARTUUID/,/^    fi/p' | grep -c 'return 1')"

echo
echo "== 9. the build copies itself into the chroot =="
# The later stages re-run this file from inside the target. If the copy is
# missing or not executable, every one of them is "no such file".
grep -q 'install -m 0755 "\$LFS_SELF" "\$LFS/root/installer.sh"' "$INSTALLER" \
    && ok "the build installs itself as /root/installer.sh (0755)" \
    || bad "the build installs itself as /root/installer.sh (0755)" "seam not found"
# `install -D` is GNU-only, so the destination directory is created first and
# plain install used. Without that mkdir the copy lands nowhere on busybox.
grep -q 'mkdir -p "\$LFS/root"' "$INSTALLER" \
    && ok "the self-copy destination directory is created first" \
    || bad "the self-copy destination directory is created first" "seam not found"
grep -q 'LFS_SELF=\${LFS_SELF:-\$(readlink -f "\${BASH_SOURCE\[0\]}")}' "$INSTALLER" \
    && ok "LFS_SELF is resolved when the file is executed" \
    || bad "LFS_SELF is resolved when the file is executed" "seam not found"
# ...and the destination name has to match what the stages invoke.
copied_to=$( sed -n 's/.*install -m 0755 "\$LFS_SELF" "\$LFS\/\(.*\)".*/\1/p' "$INSTALLER" )
invoked_as=$( grep -oE 'bash /root/installer\.sh --internal [a-z0-9-]+' "$INSTALLER" | head -1 | awk '{print $2}' )
# copied_to is relative to $LFS (the target root); invoked_as is the path as
# seen from inside the chroot. Compare the part after the mount point.
[ -n "$copied_to" ] && [ -n "$invoked_as" ] \
    && [ "$copied_to" = "${invoked_as#/}" ] \
    && ok "the copy lands where the stages look for it" \
    || bad "the copy lands where the stages look for it" "copied to '$copied_to' (under \$LFS), stages invoke '$invoked_as'"

echo
echo "== 10. the book's build functions travel inside this file =="
# This file used to need a second one: sources/generated-packages.sh, which the
# build sourced and the chroot re-entered. Every check below is about that not
# coming back, because the failure it produces -- stage 02 of a long build
# finding no such file -- is about as late and as opaque as it gets.

grep -q 'generated-packages' "$INSTALLER" \
    && bad "no reference to a generated companion file" "$(grep -n 'generated-packages' "$INSTALLER" | head -2)" \
    || ok "no reference to a generated companion file"
grep -qE '^\s*source ["'"'"']?\$?[A-Za-z_]*(GEN|GENERATED)' "$INSTALLER" \
    && bad "nothing sources a generated file at run time" "found a source of a generated file" \
    || ok "nothing sources a generated file at run time"

# The section must be delimited and appear exactly once, or book_emit either
# prints nothing or prints it twice into the child.
for m in BEGIN END; do
    n=$( grep -c "^# ---8<--- BOOK_FUNCS_$m\$" "$INSTALLER" )
    check "the book section has exactly one $m marker" "1" "$n"
done

# ...and what book_emit prints has to be what is in the file, byte for byte.
# A drift here is the difference between the chroot defining 110 functions and
# defining none, with the child's first reference failing at a pushd.
book_emit > "$M/emitted.sh"
sed -n '/^# ---8<--- BOOK_FUNCS_BEGIN$/,/^# ---8<--- BOOK_FUNCS_END$/p' "$INSTALLER" | sed '1d;$d' > "$M/insection.sh"
if cmp -s "$M/emitted.sh" "$M/insection.sh"; then
    ok "book_emit reproduces the in-file section exactly"
else
    bad "book_emit reproduces the in-file section exactly" "$(diff "$M/insection.sh" "$M/emitted.sh" | head -4)"
fi
check "the emitted section is not empty" "yes" \
      "$([ -s "$M/emitted.sh" ] && echo yes || echo no)"

# Every name in a stage list needs a function. The count itself is expected to
# move when the book changes, so it is reported and not asserted; the
# name-to-function mapping is the invariant.
staged=$( printf '%s\n' "${STAGE5[@]}" "${STAGE6[@]}" "${STAGE7[@]}" "${STAGE8[@]}" \
          | grep -c '^build_' )
defined=$( declare -F | grep -cE 'build_[0-9]+_[0-9]+_[A-Za-z0-9_]+' )
check "every stage name has a build function" "0" \
      "$(for n in "${STAGE5[@]}" "${STAGE6[@]}" "${STAGE7[@]}" "${STAGE8[@]}"; do
            declare -F "$n" >/dev/null || echo "$n"
        done | wc -l)"
printf '  (%s packages across STAGE5..8, %s build functions defined)\n' "$staged" "$defined"
for s in 5 6 7 8; do
    declare -n stage_arr="STAGE$s"
    n=${#stage_arr[@]}
    unset -n stage_arr
    [ "$n" -gt 0 ] && ok "STAGE$s is non-empty ($n packages)" \
                  || bad "STAGE$s is non-empty" "empty: the book section did not load"
done

# The distiller emits its own shebang, and a second one mid-file is a syntax
# error 2000 lines in. The file's real shebang is legitimate; a stray is not.
check "exactly one shebang, on line 1" "1" \
      "$(grep -c '^#!/usr/bin/env bash' "$INSTALLER")"
check "and it is line 1" "yes" \
      "$(head -1 "$INSTALLER" | grep -q '^#!/usr/bin/env bash' && echo yes || echo no)"
# The distiller's `set -u` is the other half of the same problem: inlined
# verbatim it silently re-enables nounset in every caller, including this file.
# shellcheck disable=SC1090  # INSTALLER path is built at runtime
( set +u; . "$INSTALLER"; case "$-" in *u*) echo leaked ;; *) echo clean ;; esac ) > "$M/flags" 2>&1
check "sourcing does not re-enable set -u" "clean" "$(cat "$M/flags")"
# shellcheck disable=SC1090  # INSTALLER path is built at runtime
( set +u; . "$INSTALLER"; case "$-" in *u*) echo leaked ;; *) echo clean ;; esac ) > "$M/flags" 2>&1
check "sourcing does not re-enable set -u" "clean" "$(cat "$M/flags")"

echo
echo "== 11. one book function is run by name, and only by name =="
# Reached from the chroot as `--internal build-one <name>`, where the name comes
# from a STAGE* array one shell away from the array's own definition. It is
# checked against the functions in this file rather than trusted, because eval
# of a name that turned out to be junk would be a poor surprise in a chroot.
check "build-one refuses an unknown name" "2" \
      "$(task_build_one nope >/dev/null 2>&1; echo $?)"
check "build-one refuses a non-build function" "2" \
      "$(task_build_one task_kernel >/dev/null 2>&1; echo $?)"
check "build-one refuses an empty name" "2" \
      "$(task_build_one '' >/dev/null 2>&1; echo $?)"
out=$( task_build_one rm 2>&1 >/dev/null )
case "$out" in
    *"non-build function"*) ok "build-one says why it refused rm" ;;
    *) bad "build-one says why it refused rm" "got: $out" ;;
esac
# A real name must get past the check and into the function. The book functions
# read SOURCES_DIR (default /mnt/lfs/sources), so point that at an empty
# directory: the run then always stops on the missing tarball, which is the
# proof it was called. Without this the check only holds on a machine with no
# sources -- on the build VM, which has them, it ran MPFR's configure for real
# and reported a gmp.h error instead.
EMPTY_SOURCES=$(mktemp -d)
out=$( SOURCES_DIR="$EMPTY_SOURCES" task_build_one build_8_24_1_MPFR 2>&1 >/dev/null )
case "$out" in
    *mpfr-4.2.2.tar.xz*) ok "build-one dispatches a real book function by name" ;;
    *) bad "build-one dispatches a real book function by name" "got: $out" ;;
esac
rm -rf "$EMPTY_SOURCES"
# book_function is the single-function extractor, used where one name is needed
# rather than all 110.
check "book_function extracts one function whole" "yes" \
      "$(book_function build_8_24_1_MPFR | grep -q '^        }$' && echo yes || echo no)"
check "book_function is quiet about a name that is not there" "0" \
      "$(book_function build_9_9_9_Nope | wc -l)"
# Chapters 7-8 run the copy of the installer that lives inside the chroot, so
# that copy has to be refreshed on EVERY run. It used to be installed by the
# chroot_tools stage, which is checkpointed -- so --resume skipped it, and a
# resumed build re-ran the installer as it was before the fix that made you
# resume in the first place. Silent, and it defeats the only reason to resume.
# Assert it is not inside any checkpointed stage.
# Matching on any mention would be wrong: build_stage_06 legitimately *runs*
# /root/installer.sh inside the chroot. What must not happen there is an
# `install` of it.
cp=$( sed -n '/^build_stage_06()/,/^}/p' "$INSTALLER" )
if printf '%s' "$cp" | grep -qE 'install[^|]*root/installer\.sh'; then
    bad "the chroot copy is not installed by a checkpointed stage" \
        "build_stage_06 still installs it, so --resume leaves it stale"
else
    ok "the chroot copy is not installed by a checkpointed stage"
fi
# ...and it IS installed unconditionally in the main flow.
if sed -n '/^lfs_main()/,/^}/p' "$INSTALLER" | grep -q 'install -m 0755 "\$LFS_SELF" "\$LFS/root/installer.sh"'; then
    ok "the chroot copy is refreshed on every run"
else
    bad "the chroot copy is refreshed on every run" "not installed in the main flow"
fi

# OpenSSL's `make test` forks daemons that outlive it -- an ECH s_server and an
# ocsp responder -- holding their working directory inside the source tree. They
# keep /mnt/lfs mounted, so the build reports "done" with the target still
# mounted, and the leftover mount is what the operator sees next time instead of
# whatever actually broke.
OPENSSL_FN=$( sed -n '/^        build_8_49_1_OpenSSL()/,/^        }/p' "$LFS_ROOT/installer.sh" )
case "$OPENSSL_FN" in
    *'pkill -f "$_d"'*) ok "OpenSSL test daemons are reaped after make test" ;;
    *) bad "OpenSSL test daemons are reaped after make test" \
          "no daemon cleanup in build_8_49_1_OpenSSL" ;;
esac
case "$OPENSSL_FN" in
    *"openssl s_server"*) ok "cleanup names the s_server daemon" ;;
    *) bad "cleanup names the s_server daemon" "s_server not in the cleanup list" ;;
esac
case "$OPENSSL_FN" in
    *"openssl ocsp"*) ok "cleanup names the ocsp daemon" ;;
    *) bad "cleanup names the ocsp daemon" "ocsp not in the cleanup list" ;;
esac
# And it must run *after* the suite, or it reaps nothing.
CLEANUP_LINE=$( printf '%s\n' "$OPENSSL_FN" | grep -n 'pkill -f' | head -1 | cut -d: -f1 )
SUITE_LINE=$( printf '%s\n' "$OPENSSL_FN" | grep -n '^ *make test' | head -1 | cut -d: -f1 )
if [ -n "$CLEANUP_LINE" ] && [ -n "$SUITE_LINE" ] && [ "$CLEANUP_LINE" -gt "$SUITE_LINE" ]; then
    ok "daemon cleanup runs after the test suite"
else
    bad "daemon cleanup runs after the test suite" \
        "cleanup at ${CLEANUP_LINE:-none}, make test at ${SUITE_LINE:-none}"
fi

# $LFS in lfs_main means the target's mount point, and lfs_main is the first
# place in the program that needs that name. It used to be set only inside
# lfs_build (`: "${LFS:=/mnt/lfs}"`), so a "$LFS/..." written in lfs_main expanded
# to "/..." -- a path on the HOST, not an error and not an empty string. The
# chroot copy of the installer was installed that way and silently landed on the
# build host's /root while the target's copy went stale.
#
# So: in lfs_main, LFS must be assigned before it is first used.
# Comments are stripped first: this file's own prose about the trap mentions
# "$LFS/..." and would otherwise be counted as a use of it. Both line numbers
# then come from that same stripped stream -- filtering one and not the other
# renumbers them apart, and the comparison ends up comparing unrelated lines.
main_code=$( sed -n '/^lfs_main()/,/^}/p' "$INSTALLER" | grep -v '^[[:space:]]*#' )
# \$LFS\b is enough on its own: "_" is a word character, so "$LFS_SELF" and
# "$LFS_TARGET_MOUNT" have no word boundary after "LFS" and cannot match.
first_use=$( printf '%s\n' "$main_code" | grep -n '\$LFS\b' | head -1 | cut -d: -f1 )
first_set=$( printf '%s\n' "$main_code" | grep -n '^ *LFS=' | head -1 | cut -d: -f1 )
if [ -n "$first_use" ] && [ -n "$first_set" ] && [ "$first_set" -lt "$first_use" ]; then
    ok "lfs_main assigns LFS before using it"
elif [ -z "$first_use" ]; then
    ok "lfs_main assigns LFS before using it (no use to precede)"
else
    bad "lfs_main assigns LFS before using it" \
        "first use of \$LFS is at relative line $first_use, first assignment at ${first_set:-none}"
fi

# The children start with `env -i`, so they cannot find the definitions
# themselves and the parent has to hand them over.
grep -q 'book_emit > "$lib"' "$INSTALLER" \
    && ok "children are handed the section as a file (env -i safe)" \
    || bad "children are handed the section as a file (env -i safe)" "seam not found"

# ...and the child has to SOURCE that file rather than cat it. This is not a
# style point: `cat` copies the bytes to stdout and bash only defines a function
# when it PARSES one, so a `{ cat; }` here produces a log full of function
# definitions and then "command not found" -- a failure that only shows up in
# stage 4, an hour into the build, in a log inside the target.
check "the child sources the section rather than cat-ing it" "yes" \
      "$(sed -n '/^build_run_lfs()/,/^}/p' "$INSTALLER" | grep -q 'source \"\$1\"' && echo yes || echo no)"

# A temp file only works if the child, which is not root, can actually read it.
# mktemp makes 0600, so this is the check that would have caught the real
# failure: the file exists and is root-owned, and the lfs user cannot open it.
check "the section file is opened up for the non-root child" "yes" \
      "$(sed -n '/^build_run_lfs()/,/^}/p' "$INSTALLER" | grep -q 'chmod 0644 "\$lib"' && echo yes || echo no)"
# ...and it must be cleaned up, or /tmp fills with a copy of the book per package.
check "the section file is removed afterwards" "yes" \
      "$(sed -n '/^build_run_lfs()/,/^}/p' "$INSTALLER" | grep -q 'rm -f "\$lib"' && echo yes || echo no)"

# Actually run the child's command, taken from the installer rather than
# retyped here. A test that hardcodes the correct shape tests itself; this one
# breaks the moment build_run_lfs does. The stage-4 failure this guards against
# lives in what bash does with the text, so grepping cannot find it -- the only
# honest check is to run the installer's own command against a probe section.
tpl=$( sed -n '/^build_run_lfs()/,/^}/p' "$INSTALLER" \
       | sed -n "s/.*bash -e -c '\(.*\)'[[:space:]]*\"\\\$fn\".*/\1/p" )
if [ -z "$tpl" ]; then
    bad "build_run_lfs's child command could be extracted" "seam not found"
else
    ok "build_run_lfs's child command could be extracted"
    # Written to a file, world-readable, and passed the way build_run_lfs passes
    # it ($0 is a dummy, the path is $1) -- the template reads $1.
    PROBE=$(mktemp)
    chmod 0644 "$PROBE"
    # $1 is what to CALL, $2 is what the section defines.
    probe() { printf '%s\n' "$2" > "$PROBE"; env -i PATH=/usr/bin:/bin HOME=/tmp TERM=xterm \
                  bash -e -c "${tpl}$1" lfs-book "$PROBE" 2>&1; }
    out=$( probe probe_fn 'probe_fn() { echo PROBE_RAN; }' )
    check "the child defines and calls a function from the section" "PROBE_RAN" "$out"
    out=$( probe probe_fn 'probe_list=( a b c )
probe_fn() { echo ${#probe_list[@]}; }' )
    check "and the child can see arrays too" "3" "$out"
    rm -f "$PROBE"

    # The one that matters most, and the one every other check here missed.
    # build_run_lfs's child drops privileges to lfs. A section handed over in a
    # way only the *owner* can read -- a pipe reopened through /proc/self/fd,
    # a 0600 mktemp file -- works perfectly in this suite, because here the
    # child runs as the same user that made it. It then fails in the real build
    # with "Permission denied" in a log inside the target, hours in.
    # So: make the section root-owned, read it as somebody else.
    if [ "$(id -u)" != 0 ] || ! command -v runuser >/dev/null 2>&1; then
        printf '  skip cross-user section test: needs root and runuser\n'
    elif ! id nobody >/dev/null 2>&1; then
        printf '  skip cross-user section test: no "nobody" user\n'
    else
        XP=$(mktemp)
        printf 'probe_fn() { echo CROSS_USER_OK; }\n' > "$XP"
        chmod 0644 "$XP"          # what build_run_lfs does
        chmod 0600 "$XP"          # and what a careless mktemp would leave
        out=$( runuser -u nobody -- env -i PATH=/usr/bin:/bin HOME=/tmp TERM=xterm \
                   bash -e -c "${tpl}probe_fn" lfs-book "$XP" 2>&1 )
        check "a 0600 section is NOT readable by the child user" \
              "CROSS_USER_DENIED_YES" \
              "$(printf '%s' "$out" | grep -q 'CROSS_USER_OK' && echo CROSS_USER_DENIED_NO || echo CROSS_USER_DENIED_YES)"
        chmod 0644 "$XP"
        out=$( runuser -u nobody -- env -i PATH=/usr/bin:/bin HOME=/tmp TERM=xterm \
                   bash -e -c "${tpl}probe_fn" lfs-book "$XP" 2>&1 )
        check "a 0644 section IS readable by the child user" "CROSS_USER_OK" "$out"
        rm -f "$XP"
    fi
fi
# The real section, through the real child command, in a real empty environment.
REAL=$(mktemp); chmod 0644 "$REAL"; book_emit > "$REAL"
real_child() { env -i PATH=/usr/bin:/bin TERM=xterm \
                   bash -e -c "${tpl}$1" lfs-book "$REAL" 2>&1; }
out=$( real_child 'declare -F build_5_2_1_Cross_Binutils >/dev/null && echo DEFINED' )
check "the real book section defines a real function" "DEFINED" "$out"
out=$( real_child 'declare -F' | grep -c '^declare -f build_[0-9]' )
check "and defines all 110 of them" "110" "$out"
out=$( real_child 'echo ${#STAGE5[@]}+${#STAGE6[@]}+${#STAGE7[@]}+${#STAGE8[@]}' )
check "and the four stage lists" "5+17+8+80" "$out"

echo
echo "== 5. UEFI takeover wiring survives the merge =="
# These are the parts of a UEFI install that live in different sections of the
# one file and have to agree: lfs_main mounts the target ESP, the chroot task
# writes its UUID into fstab, and the bootable task installs both the named and
# the removable EFI bootloader. A merge that drops any one of them produces an
# install that completes and then does not boot.
in_str()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing: $3" ;; esac; }
# Ordering matters as much as presence: a guard that runs after the destructive
# step it was meant to prevent is not a guard.
before_in() {  # before_in HAYSTACK NEEDLE BLOCK LABEL -- BLOCK starts before NEEDLE
    local block_first
    block_first="${3%%$'\n'*}"
    case "$1" in
        *"$block_first"*"$2"*) ok "$4" ;;
        *) bad "$4" "$block_first appears after $2" ;;
    esac
}
not_in()  { case "$2" in *"$3"*) bad "$1" "present: $3" ;; *) ok "$1" ;; esac; }

# build_stage_09 preflights on the HOST, before entering the chroot, so a missing
# identity is named in one list instead of surfacing an hour into the kernel
# build. LFS_ROOT_PARTUUID belongs in that list on BOTH firmware paths: the GRUB
# rewrite turns it into root=PARTUUID=, and an empty one writes
# root=PARTUUID= -- an identifier nothing matches, which is exactly the silent
# rescue-prompt failure this rewrite exists to prevent.
STAGE9=$( sed -n '/^build_stage_09()/,/^}/p' "$INSTALLER" )
for v in LFS_ROOT_DEV LFS_ROOT_UUID LFS_ROOT_PARTUUID; do
    in_str "the stage-09 preflight requires $v" "$STAGE9" "$v"
done
# Strip the firmware branch, so this fails if the check is ever moved inside it.
STAGE9_UNBRANCHED=$(printf '%s' "$STAGE9" | sed '/if \[ "\$LFS_FIRMWARE" = bios \]/,/^    fi/d')
in_str "the PARTUUID preflight is not inside the BIOS-only branch" \
      "$STAGE9_UNBRANCHED" "LFS_ROOT_PARTUUID"

MAIN=$(sed -n '/^lfs_main()/,/^}/p' "$INSTALLER")
TASKBOOT=$(sed -n '/^task_bootable()/,/^}/p' "$INSTALLER")
in_str "takeover mounts the target ESP"   "$MAIN" 'mount "$ESP_DEV" "$LFS_TARGET_MOUNT$ESP"'
in_str "takeover exports LFS_ESP_UUID"    "$MAIN" 'LFS_ESP_UUID=$(blkid -s UUID -o value "$ESP_DEV"'
in_str "takeover registers the NVRAM entry" "$MAIN" 'boot_register_nvram "$TARGET_ESP"'
# The Secure Boot refusal must be in lfs_main, ahead of any destructive step,
# and must name the two real alternatives rather than a vague failure.
in_str "refuses Secure Boot for takeover" "$MAIN" "Secure Boot is enabled, and a freshly built GRUB is unsigned"
in_str "refusal names the side-by-side path" "$MAIN" "side-by-side"
# --help is how a user learns the GPT requirement before they hit the refusal,
# so the constraint belongs in the usage text and not only in the die message.
in_str "--help states the side-by-side GPT requirement" \
      "$(sed -n '/--mode MODE/,/--firmware MODE/p' "$INSTALLER")" "must be on a GPT disk"

# A cross-reference that names the wrong section sends the reader to unrelated
# text, and it fails silently: section numbers shift whenever anything above
# them is edited. Check that each pointer still lands on a heading that is
# actually about what the reference claims.
# The section number must be READ FROM the reference, not passed in beside it:
# passing it in would let the expected and the actual be the same value by
# construction, and the check would pass on a reference that names section 6.
check_section() {  # check_section FROM REF RESOLVE-IN EXPECTED-HEADING-FRAGMENT
    local from=$1 ref=$2 file=$3 want=$4 line sec heading
    # FROM holds the reference; RESOLVE-IN is where the numbered section lives,
    # which is not always FROM -- README.md points into MANUAL.md by number.
    line=$( grep -m1 -F "$ref" "$from" )
    sec=$( printf '%s' "$line" | sed -n 's/.*section \([0-9][0-9]*\).*/\1/p' )
    if [ -z "$sec" ]; then
        bad "the reference containing \"$ref\" names a section" "no 'section N' in: $line"
        return
    fi
    heading=$( grep -m1 "^## $sec\\. " "$file" )
    case "$heading" in
        *"$want"*) ok "the reference containing \"$ref\" names section $sec, which is about '$want'" ;;
        *)        bad "the reference containing \"$ref\" names section $sec, which is about '$want'" \
                      "section $sec is: ${heading:-<none>}" ;;
    esac
}
# The needle must sit on the line that actually carries "section N", or the
# lookup below finds no number and the check reports the wrong failure.
check_section MANUAL.md 'reasons given under' MANUAL.md 'Choosing a target'
check_section MANUAL.md 'see "What it refuses to touch" in section' MANUAL.md 'Choosing a target'
check_section README.md 'out of scope rather than merely untested' MANUAL.md 'Requirements'
# A side-by-side target that is not GPT has no PARTUUID, and this kernel cannot
# mount the root by filesystem UUID either, so there is no identifier that
# survives a re-enumeration. The refusal must come before the build, and it must
# not look like the "internal error" the callee would otherwise produce.
PARTUUID_GUARD=$(printf '%s' "$MAIN" | sed -n '/has no PARTUUID/,/^ *fi$/p')
in_str "an MBR side-by-side target is refused"    "$PARTUUID_GUARD" 'no PARTUUID'
in_str "the MBR refusal explains why"            "$PARTUUID_GUARD" 'not GPT'
in_str "the MBR refusal offers takeover"         "$PARTUUID_GUARD" 'mode takeover'
before_in "$MAIN" 'say "building LFS' "$PARTUUID_GUARD" \
    "the MBR refusal comes before the build"
# The chroot side: fstab must carry /boot/efi keyed on the ESP UUID, and the
# bootable task must write the removable fallback as well as the named entry.
in_str "fstab gets a /boot/efi entry"     "$TASKBOOT" '/boot/efi'
in_str "fstab keys it on the ESP UUID"    "$TASKBOOT" 'LFS_ESP_UUID'
in_str "installs the named EFI bootloader" "$TASKBOOT" 'bootloader-id='
in_str "installs the removable fallback"  "$TASKBOOT" '--removable'
# The chroot hand-off must pass both new variables or the bootable stage sees
# them unset and either skips fstab or writes a bad one.
CHROOT=$(sed -n '/^lfs_enter_chroot()/,/^}/p' "$INSTALLER")
in_str "chroot hand-off passes LFS_ESP_UUID" "$CHROOT" 'LFS_ESP_UUID='
in_str "chroot hand-off passes LFS_BOOT_ID"  "$CHROOT" 'LFS_BOOT_ID='

echo
echo "== 6. --plan completes on a machine with nothing installed yet =="
# A preview is the first thing a user runs, usually on a machine that has no
# build toolchain. Two things used to abort the preview instead of describing
# it: deps_verify called die(), which exits the whole script, and ESP was only
# assigned outside the dry-run branch, so the plan printed "the ESP at ,".
# This suite may run on a refused distro (Omarchy dev machines, Arch hosts),
# where lfs_detect_distro dies by design. That refusal is correct and covered
# by test_boot; it is not what this block is testing. Pretend to be a supported
# build host by pointing the detector at a fixture os-release, so the preview
# path is exercised on any machine.
FAKE_OSREL=$(mktemp); printf 'ID=ubuntu\nID_LIKE=debian\nVERSION_ID="24.04"\nPRETTY_NAME="Ubuntu 24.04"\n' > "$FAKE_OSREL"
# The disk itself only has to exist as a name under /dev: the existing
# LFS_FAKE_BLOCKDEVS seam is how the suites stand in for a block device without
# root, so no real (or loop) device is created or touched.
FAKE_DISK=/dev/lfs-test-plan-disk
# Firmware and a target are injected too: on an ordinary dev machine there is no
# blank disk to auto-select and the firmware is BIOS, so without those the run
# stops at "attach a blank disk" and never reaches the preview output.
out=$( bash -c '
    source "$1"
    LFS_OSRELEASE=$2 LFS_DRY_RUN=1 LFS_FIRMWARE=uefi LFS_TARGET=$3 \
        LFS_FAKE_BLOCKDEVS=$3 lfs_main
' _ "$INSTALLER" "$FAKE_OSREL" "$FAKE_DISK" 2>&1 ); rc=$?
rm -f "$FAKE_OSREL"
check "a preview on a bare machine still finishes" "0" "$rc"
in_str "the plan names the in-target ESP path" "$out" "would mount the ESP at /boot/efi"
not_in "the plan never prints an empty ESP path" "$out" "at , install GRUB"
# The same preview must also describe the self-copy and still report its
# planned target and the irreversible step, so it is a usable preview end to
# end rather than one that stops at the first unmounted directory.
in_str "the plan describes the self-copy into the target" "$out" "would install"
in_str "the plan names the target it would erase"   "$out" "IRREVERSIBLE"
in_str "the plan ends with the boot promise"         "$out" "now boots LFS on its own"
not_in "a preview does not try to copy itself for real" "$out" "self->chroot copy FAILED"
# The check must report rather than gate, and must still name what is missing.
# On a build host the tools are already installed, so the preview has nothing
# to report: the line only appears when something is genuinely missing.
case "$out" in
    *"build tools that would be installed now"*) ok "the preview names any missing tools" ;;
    *"all required build tools present"*)       ok "the preview confirms tools already present" ;;
    *) bad "the preview accounts for build tools" "neither reported missing nor present" ;;
esac
not_in "a preview never hits the post-install die()" "$out" "these required tools are still missing after install"

# deps_verify is the gate that turns "a package name was wrong" into a clear list
# instead of a confusing failure hours in. It checks BINARIES, so the list has to
# contain the commands the script actually calls. It used to require `fdisk`,
# which this script never calls, while target_prepare creates every partition and
# every GPT flag with `parted`, which nothing required. A host without parted
# passed this gate and then died at the first partition step.
DEPS_VERIFY=$(sed -n '/^deps_verify()/,/^}/p' "$INSTALLER")
# curl is the one the fetcher actually calls (task_fetch_sources uses curl, not
# wget). It was missing from the list while wget -- never invoked -- was
# installed, so a host with neither failed at the first download.
for t in gcc g++ make ld as awk sed grep tar xz patch find mount blkid mkfs.ext4 \
         parted chroot uname python3 curl; do
    in_str "deps_verify requires $t" "$DEPS_VERIFY" "$t"
done
not_in "deps_verify does not require the never-called fdisk" "$DEPS_VERIFY" "mkfs.ext4 fdisk"
# --plan duplicates the list inline (it cannot call deps_verify, which dies).
# If the two drift, the preview promises tools the real run would reject.
PLAN_LIST=$(printf '%s' "$out" >/dev/null; grep -A3 'for dtool in' "$INSTALLER" | tr -s ' \n' ' ')
for t in parted curl; do
    in_str "the plan's inline tool list also requires $t" "$PLAN_LIST" "$t"
done

echo
echo "== 7. the lfs user's login shell gets a real job count =="
# build_stage_03_lfsusr writes /home/lfs/.bashrc, and that file is the only
# thing the lfs user's shell has. It used to contain MAKEFLAGS="-j$(lfs_job_count)",
# but lfs_job_count is a function of the installer: a login shell has never heard
# of it, so the count expanded to nothing and MAKEFLAGS became a bare "-j", which
# GNU make reads as UNLIMITED parallelism. The memory cap inverted into the exact
# setting that makes an 8 GB build thrash. Nothing read the file, so nothing
# caught it.
#
# The file is generated, so the check is on the generated file: call the REAL
# producer (emit_lfs_bashrc) and source its output with an empty environment,
# which is what the lfs user's shell effectively is. This test used to rebuild
# the heredocs here by hand, which meant it passed against a copy -- a regression
# in the generator would have left this passing and the real file broken.
BRC_DIR=$(mktemp -d)
mkdir -p "$BRC_DIR/mnt"
LFS_TGT=x86_64-lfs-linux-gnu
LFS="$BRC_DIR/mnt"
JOBS_EXPECTED=$( lfs_job_count )
emit_lfs_bashrc > "$BRC_DIR/bashrc"
out=$( env -i HOME="$BRC_DIR" /bin/bash -c '. "$1"; printf "%s" "$MAKEFLAGS"' _ "$BRC_DIR/bashrc" 2>&1 )
check "the login shell resolves a job count" "-j$JOBS_EXPECTED" "$out"
case "$out" in
    "-j") bad "MAKEFLAGS is never a bare -j (that means unlimited)" \
             "got a bare -j; make would run every target at once" ;;
    "-j"[0-9]*) ok "MAKEFLAGS carries an explicit number" ;;
    *) bad "MAKEFLAGS carries an explicit number" "got: $out" ;;
esac
# And the count must still be bounded by the CPU count, which is the other half
# of the cap: more jobs than cores is pure context switching.
JOBS=${out#-j}
CPUS=$(nproc)
if [ "$JOBS" -ge 1 ] 2>/dev/null && [ "$JOBS" -le "$CPUS" ]; then
    ok "the job count is within 1..nproc"
else bad "the job count is within 1..nproc" "got $JOBS with nproc=$CPUS"; fi
rm -rf "$BRC_DIR"

# The test above calls the real producer, so it can only fail if the generator is
# broken. This is the other direction: prove the suite would notice. Reintroduce
# the original bug -- defer the count to the login shell, which has never heard
# of lfs_job_count -- and the suite has to fail. A test that cannot be shown to
# fail is not evidence.
BRC2=$(mktemp -d)
mkdir -p "$BRC2/mnt"
LFS="$BRC2/mnt"
LFS_TGT=x86_64-lfs-linux-gnu
# The bug, verbatim: $(lfs_job_count) written into the file instead of resolved.
{
    cat <<EOF
set +h
umask 022
LFS=$BRC2/mnt
LC_ALL=POSIX
LFS_TGT=$LFS_TGT
EOF
    cat <<EOF
PATH=/usr/bin
PATH=\$LFS/tools/bin:\$PATH
CONFIG_SITE=\$LFS/usr/share/config.site
MAKEFLAGS="-j\$(lfs_job_count)"
export LFS LC_ALL LFS_TGT PATH CONFIG_SITE MAKEFLAGS
EOF
} > "$BRC2/bashrc"
bugged=$( env -i HOME="$BRC2" /bin/bash -c '. "$1"; printf "%s" "$MAKEFLAGS"' _ "$BRC2/bashrc" 2>/dev/null )
# Run the buggy output through the SAME verdict the real check uses above. If the
# bug reproduces to the bare -j that verdict rejects, the check bites.
case "$bugged" in
    "-j") ok "the job-count check rejects a deferred lfs_job_count" ;;
    *) bad "the job-count check rejects a deferred lfs_job_count" \
            "expected the buggy file to resolve to a bare -j, got: $bugged" ;;
esac
rm -rf "$BRC2"

echo
echo "== 11. the generated shell is lint-clean =="
# 0 errors and 0 warnings is the bar. The remaining notes are a different
# matter: they are all inside the book's own section, which is upstream text
# emitted verbatim, and quoting its globs would change what runs. So the gate
# does not merely count notes -- it proves none of them are ours.
if command -v shellcheck >/dev/null 2>&1; then
    SC_OUT=$(shellcheck -f gcc "$INSTALLER" 2>&1)
    SC_ERR=$(printf '%s\n' "$SC_OUT" | grep -c 'error:')
    SC_WARN=$(printf '%s\n' "$SC_OUT" | grep -c 'warning:')
    [ "$SC_ERR" -eq 0 ] \
        && ok "shellcheck reports no errors" \
        || bad "shellcheck reports no errors" "$SC_ERR error(s)"
    [ "$SC_WARN" -eq 0 ] \
        && ok "shellcheck reports no warnings" \
        || bad "shellcheck reports no warnings" "$SC_WARN warning(s)"

    BOOK_B=$(grep -n '^# ---8<--- BOOK_FUNCS_BEGIN$' "$INSTALLER" | head -1 | cut -d: -f1)
    BOOK_E=$(grep -n '^# ---8<--- BOOK_FUNCS_END$'   "$INSTALLER" | head -1 | cut -d: -f1)
    if [ -n "$BOOK_B" ] && [ -n "$BOOK_E" ]; then
        OUTSIDE=$(printf '%s\n' "$SC_OUT" | grep 'note:' \
                  | awk -F: -v b="$BOOK_B" -v e="$BOOK_E" '$2<b || $2>e' \
                  | wc -l)
        [ "$OUTSIDE" -eq 0 ] \
            && ok "every shellcheck note is inside the verbatim book section" \
            || bad "every shellcheck note is inside the verbatim book section" \
                   "$OUTSIDE note(s) outside lines $BOOK_B..$BOOK_E"
    else
        bad "the book section markers are findable" "markers not found"
    fi
else
    echo "  skip shellcheck not installed"
fi

printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then printf 'failing:%s\n' "$FAILED_NAMES"; exit 1; fi
printf 'ALL SINGLE-FILE TESTS PASSED\n'
exit 0
