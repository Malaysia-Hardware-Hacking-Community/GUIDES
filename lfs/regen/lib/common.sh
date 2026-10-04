#!/usr/bin/env bash
# Shared logging and error helpers. Source, never execute.
#
# Every unit (detect/deps/target/boot) sources this so that output formatting,
# log-file handling and the dry-run gate are defined in exactly one place. The
# dry-run gate matters most: target selection and boot installation can make a
# machine unbootable, so every mutating call goes through `run` and is
# suppressed under
# --plan rather than each unit growing its own copy of that check.

[ -n "${_LFS_COMMON_SH:-}" ] && return 0
_LFS_COMMON_SH=1

# Log file for the whole run. Appended to, so a --resume run keeps history.
: "${LFS_LOG:=/var/log/installer.log}"

# 1 = print the command and skip it, 0 = run it for real.
: "${LFS_DRY_RUN:=0}"

_ts() { date '+%Y-%m-%d %H:%M:%S'; }

# Append to the log file, best-effort.
#
# Must never be able to break the caller. Previewing a plan as a normal user is
# a legitimate thing to do, and the default /var/log/installer.log is not
# writable without root -- which used to print a tee error in front of every
# single line and bury the actual plan.
_logappend() {
    [ -n "${LFS_LOG:-}" ] || return 0
    local dir
    dir=$(dirname "$LFS_LOG" 2>/dev/null) || return 0
    [ -d "$dir" ] && [ -w "$dir" ] || return 0
    printf '%s\n' "$1" >> "$LFS_LOG" 2>/dev/null || true
}

_log() {
    # $1 = level, rest = message
    local level="$1"; shift
    local line
    line=$(printf '%s [%-5s] %s' "$(_ts)" "$level" "$*")
    printf '%s\n' "$line" >&2
    _logappend "$line"
}

say()  { _log "info" "$@"; }
warn() { _log "warn" "$@"; }
die()  { _log "fatal" "$@"; exit 1; }

# run CMD ARG... -- execute unless --plan, in which case just show what would run.
#
# This is the only sanctioned way for a unit to touch the system. Anything that
# mutates disks, partitions, or bootloader config MUST go through here, so that
# `bootstrap.sh --plan` is trustworthy by construction rather than by everyone
# remembering to check the flag.
#
# Takes varargs, not one string, and executes argv[0] with the rest as
# arguments. Passing a single quoted string therefore executes a program whose
# name is the whole string: "run 'parted -s /dev/vdc mklabel gpt'" fails with
# ENOENT for a binary that is installed. The printed output is identical either
# way, so --plan cannot detect that mistake -- which is why the argument
# handling is fixed here rather than left to each call site.
run() {
    if [ "$LFS_DRY_RUN" = 1 ]; then
        local line
        line=$(printf '%s [PLAN ] would run: %s' "$(_ts)" "$*")
        printf '%s\n' "$line" >&2
        _logappend "$line"
        return 0
    fi
    local line
    line=$(printf '%s [exec ] %s' "$(_ts)" "$*")
    printf '%s\n' "$line" >&2
    _logappend "$line"
    "$@"
}

# same as run(), but for shell snippets that need redirection/pipes. The
# snippet is printed under --plan and eval'd otherwise.
runsh() {
    if [ "$LFS_DRY_RUN" = 1 ]; then
        local line
        line=$(printf '%s [PLAN ] would run: %s' "$(_ts)" "$1")
        printf '%s\n' "$line" >&2
        _logappend "$line"
        return 0
    fi
    local line
    line=$(printf '%s [exec ] %s' "$(_ts)" "$1")
    printf '%s\n' "$line" >&2
    _logappend "$line"
    bash -c "$1"
}

# A gate for anything irreversible. Under --plan it is always allowed (that is
# the point of a plan); otherwise it demands an explicit acknowledgement.
# $1 = what is about to happen, $2 = the env var that must be set to yes.
confirm_irreversible() {
    local what="$1" ack_var="${2:-LFS_I_UNDERSTAND}"
    if [ "$LFS_DRY_RUN" = 1 ]; then
        local line
        line=$(printf '%s [PLAN ] IRREVERSIBLE: %s' "$(_ts)" "$what")
        printf '%s\n' "$line" >&2
        _logappend "$line"
        return 0
    fi
    if [ "${!ack_var:-}" = "yes" ]; then
        return 0
    fi
    # Interactive gate. A plain `sudo ./installer.sh` runs on a terminal, and a
    # terminal has a human at it, so ask. Without this the documented one-liner
    # could never complete: --yes was described as skipping a prompt that did
    # not exist, so a bare run only ever died demanding an env var.
    #
    # Anything that is not a terminal -- nohup, cron, CI, a piped run -- has no
    # human to answer, so it falls through to the refusal rather than blocking
    # on a read that will never return.
    if [ -t 0 ] && [ -t 2 ]; then
        local reply=""
        printf '\n  About to happen:\n    %s\n' "$what" >&2
        printf '\n  This cannot be undone. Type yes to continue: ' >&2
        IFS= read -r reply || reply=""
        if [ "$reply" = "yes" ]; then
            return 0
        fi
        die "not confirmed ('$reply'), stopping before anything was changed.
  Re-run with --plan to see the full list of changes first, or --yes to
  acknowledge non-interactively."
    fi
    die "refusing to do something irreversible without $ack_var=yes
  What is about to happen: $what
  Re-run with --plan first to see the full list of changes.
  (There is no terminal to prompt on: pass --yes to acknowledge.)"
}

# in_list NEEDLE HAYSTACK... -- membership test over the arguments as given.
in_list() {
    local needle="$1"; shift
    # An empty needle must never match -- not even an empty list. Callers ask
    # "is this device/distro exempt?", and a vacuous match on an unset value
    # would wave a dangerous operation straight through. This guard used to be
    # an accident rather than a decision: unquoted $@ turned one empty argument
    # into zero words, so the loop below never ran and the function fell
    # through to "no match". Quoting $@ to stop word-splitting removed the
    # accident, so the intent is now stated rather than relied upon.
    [ -n "$needle" ] || return 1
    local item
    # "$@", not $@: an element containing a space is one element. Unquoted, it
    # word-splits, so it could never match and the needle could match the wrong
    # fragment of it -- and an unquoted $@ also globs against the cwd.
    for item in "$@"; do
        [ "$item" = "$needle" ] && return 0
    done
    return 1
}

# lfs_job_count -- how many parallel make jobs to allow, for -j.
#
# Not simply $(nproc). GCC compiling glibc peaks at roughly 1.5 GB per cc1, so
# -j on a many-core machine asks for more memory than the box has; the OOM
# killer then takes a compiler out mid-object and the build fails with an error
# that reads like a corrupt source tree rather than "out of memory". Capping by
# memory turns that into a slower build instead of a dead one.
#
# MemAvailable, not MemFree: on a machine that has just booted, most of what
# looks like free memory is reclaimable page cache, and budgeting against it
# would leave the build one fork short of trouble.
#
# LFS_JOBS overrides everything, for a box whose real limit is something this
# cannot see (a cgroup limit that does not match /proc/meminfo, a shared host).
lfs_job_count() {
    local cpu mem_kb jobs
    if [ -n "${LFS_JOBS:-}" ]; then
        printf '%s' "$LFS_JOBS"
        return 0
    fi
    cpu=$(nproc 2>/dev/null || printf '1')
    mem_kb=$(awk '/^MemAvailable:/ {print $2; exit}' /proc/meminfo 2>/dev/null)
    # No /proc/meminfo (a non-Linux host, or a container with it hidden): the
    # CPU count is the best guess available and is what this did before.
    case "${mem_kb:-}" in
        ''|*[!0-9]*) printf '%s' "$cpu"; return 0 ;;
    esac
    # 1.5 GB per job, rounded down: jobs = mem_MiB / 1536.
    jobs=$(( mem_kb / 1024 / 1536 ))
    [ "$jobs" -lt 1 ] && jobs=1
    [ "$jobs" -gt "$cpu" ] && jobs="$cpu"
    printf '%s' "$jobs"
}
