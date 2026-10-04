#!/usr/bin/env bash
# Tests for the build pipeline: source fetching and per-package checkpoints.
#
# Both of these were added after an audit measured the fetch loop running one
# curl at a time (RTT-bound: 17.6s for 113 files against a 150ms/request
# server, versus 2.4s at -P8) and found stages 04/05/06 rebuilding all 31
# packages after a late failure, while stage 07 already checkpointed per
# package. These tests pin the fixed behaviour.
#
# No root, no real network: a local python server stands in for the mirror.
#
# Run:  bash lfs/tests/test_build.sh
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
LFS_ROOT=$(cd "$HERE/.." && pwd)
M=$(mktemp -d)

PASS=0; FAIL=0; FAILED_NAMES=""
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); FAILED_NAMES="$FAILED_NAMES $1"; printf '  FAIL %s\n     %s\n' "$1" "$2"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected: $2
     actual:   $3"; fi; }

export LFS_LOG="$M/log"
export LFS_MOUNTS_FILE="$M/mounts"
export LFS_DRY_RUN=0

# shellcheck source=/dev/null
source "$LFS_ROOT/installer.sh"

SRV_PID=""
cleanup() {
    [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null
    rm -rf "$M"
}
trap cleanup EXIT

stop_mirror() {
    [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null
    SRV_PID=""
    sleep 0.3
}

PORT=8757

# stand up a local mirror serving $1 (a directory), recording peak concurrency
# into $2. The latency is deliberate: without it a serial fetcher and a
# parallel one finish in the same time and the test proves nothing.
start_mirror() {
    local root="$1" peak_file="$2"
    stop_mirror
    cat > "$M/mirror.py" <<'PYEOF'
import http.server, socketserver, sys, os, threading, time
ROOT, PORT, PEAK = sys.argv[1], int(sys.argv[2]), sys.argv[3]
LAT = 0.12
lock = threading.Lock()
state = {"cur": 0, "peak": 0}
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        with lock:
            state["cur"] += 1
            state["peak"] = max(state["peak"], state["cur"])
        time.sleep(LAT)
        p = os.path.join(ROOT, self.path.lstrip("/"))
        if os.path.isfile(p):
            with open(p, "rb") as fh:
                data = fh.read()
            self.send_response(200)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        else:
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
        with lock:
            state["cur"] -= 1
            with open(PEAK, "w") as fh:
                fh.write(str(state["peak"]))
    def log_message(self, *a):
        pass
class S(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True
S(("127.0.0.1", PORT), H).serve_forever()
PYEOF
    # stdout/stderr to a file: a background process holding the suite's stdout
    # would wedge the $( ) capture in run-all.sh.
    python3 "$M/mirror.py" "$root" "$PORT" "$peak_file" >"$M/mirror.log" 2>&1 &
    SRV_PID=$!
    local i
    for i in $(seq 1 25); do
        # no -f: the mirror answers /ping with 404 (no such file), which is a
        # perfectly good sign that it is listening. -f would treat that as a
        # connection failure and the probe would never succeed.
        if curl -sS "http://127.0.0.1:$PORT/ping" -o /dev/null 2>/dev/null; then
            return 0
        fi
        sleep 0.2
    done
    echo "  FAIL mirror did not start on port $PORT"
    cat "$M/mirror.log"
    return 1
}

# build a mirror tree: $1 = dir, $2 = how many tarballs
make_mirror_tree() {
    local dir="$1" n="$2" i
    mkdir -p "$dir"
    : > "$dir/wget-list"
    : > "$dir/md5sums"
    for i in $(seq 1 "$n"); do
        printf 'payload %s\n' "$i" > "$dir/pkg-$i.tar.xz"
        printf 'http://127.0.0.1:%s/pkg-%s.tar.xz\n' "$PORT" "$i" >> "$dir/wget-list"
        ( cd "$dir" && md5sum "pkg-$i.tar.xz" >> md5sums )
    done
}

echo "== 1. task_fetch_sources fetches in parallel =="
TREE="$M/tree1"; PEAK="$M/peak1"
make_mirror_tree "$TREE" 12
start_mirror "$TREE" "$PEAK" || bad "mirror starts" "see above"
export LFS="$M/lfs1"
# the mirror base must be overridable, or this suite can only ever hit the real
# linuxfromscratch.org -- and a test that needs the internet is not a test
export LFS_DOWNLOAD_BASE="http://127.0.0.1:$PORT"
# timeout guard: until LFS_DOWNLOAD_BASE is honoured this reaches for the real
# mirror, and the production retry policy (8 retries, 3s delay) would leave the
# suite hanging instead of failing. Bounded, it fails for the right reason.
# `timeout` execs a binary, not a shell function, so the function has to be
# exported for the child bash to inherit it.
export -f task_fetch_sources
OUT=$( timeout 60 bash -c task_fetch_sources 2>&1 ); RC=$?
unset -f task_fetch_sources

n=$(find "$LFS/sources" -maxdepth 1 -name '*.tar.xz' 2>/dev/null | wc -l)
unset LFS_DOWNLOAD_BASE

if [ "$RC" -eq 0 ]; then
    ok "fetch succeeds against a local mirror"
else
    bad "fetch succeeds against a local mirror" "rc=$RC out=$OUT"
fi
case "$OUT" in
    *SOURCES-OK*) ok "fetch reports SOURCES-OK" ;;
    *) bad "fetch reports SOURCES-OK" "out=$OUT" ;;
esac
check "all 12 tarballs landed" "12" "$n"

PEAKN=$(cat "$PEAK" 2>/dev/null || echo 0)
if [ "${PEAKN:-0}" -ge 2 ]; then
    ok "fetches concurrently (peak $PEAKN in flight)"
else
    bad "fetches concurrently (peak $PEAKN in flight)" "peak concurrency was $PEAKN; expected >= 2 (serial loop)"
fi

echo "== 2. a missing required file is reported, and so is every other =="
# section 1 unset -f'd the function to keep the exported child clean; restore it
# shellcheck source=/dev/null
source "$LFS_ROOT/installer.sh"
# The old serial loop returned on the first required 404, so N missing files
# cost N runs. Every required miss must now appear in a single pass.
TREE2="$M/tree2"; PEAK2="$M/peak2"
mkdir -p "$TREE2"
: > "$TREE2/wget-list"
: > "$TREE2/md5sums"
for i in 1 2 3; do
    printf 'payload %s\n' "$i" > "$TREE2/pkg-$i.tar.xz"
    printf 'http://127.0.0.1:%s/pkg-%s.tar.xz\n' "$PORT" "$i" >> "$TREE2/wget-list"
    ( cd "$TREE2" && md5sum "pkg-$i.tar.xz" >> md5sums )
done
# two required files listed with md5 entries but never served -> hard 404s
for bad in gone-a.tar.xz gone-b.tar.xz; do
    printf 'http://127.0.0.1:%s/%s\n' "$PORT" "$bad" >> "$TREE2/wget-list"
    printf 'd41d8cd98f00b204e9800998ecf8427e  %s\n' "$bad" >> "$TREE2/md5sums"
done
start_mirror "$TREE2" "$PEAK2" || bad "mirror starts (section 2)" "see above"
export LFS="$M/lfs2"
mkdir -p "$LFS"
export LFS_DOWNLOAD_BASE="http://127.0.0.1:$PORT"
export -f task_fetch_sources
OUT2=$( timeout 60 bash -c task_fetch_sources 2>&1 ); RC2=$?
unset -f task_fetch_sources
unset LFS_DOWNLOAD_BASE

if [ "$RC2" -ne 0 ]; then
    ok "fetch fails when a required file is missing"
else
    bad "fetch fails when a required file is missing" "rc=0; a required 404 was accepted"
fi
case "$OUT2" in
    *gone-a.tar.xz*) ok "first missing required file is named" ;;
    *) bad "first missing required file is named" "out=$OUT2" ;;
esac
case "$OUT2" in
    *gone-b.tar.xz*) ok "second missing required file is named in the same pass" ;;
    *) bad "second missing required file is named in the same pass" "out=$OUT2" ;;
esac
nd=$(find "$LFS/sources" -maxdepth 1 -name '*.tar.xz' 2>/dev/null | wc -l)
check "the 3 good files still landed despite the failures" "3" "$nd"
stop_mirror

echo "== 3. stages 04/05/06 checkpoint per package =="
# Stage 07 already checkpoints per package; 04/05/06 did not, so a failure on
# the last of chapter 6's 17 packages (GCC is in there) discarded the lot.
# build_run_lfs actually compiles software, so it is stubbed to a recorder --
# the thing under test is the checkpoint logic around it, not the build.
# shellcheck source=/dev/null
source "$LFS_ROOT/installer.sh"
export STAGEDIR="$M/stages3" LOGDIR="$M/logs3" LFS="$M/lfs3"
rm -rf "$STAGEDIR" "$LOGDIR"; mkdir -p "$STAGEDIR" "$LOGDIR" "$LFS/sources"
printf 'A\n' > "$LFS/sources/fake-a.tar.xz"
printf 'B\n' > "$LFS/sources/fake-b.tar.xz"
declare -A PKG_SRC=()
PKG_SRC[fake_6_01_A]="fake-a.tar.xz"
PKG_SRC[fake_6_02_B]="fake-b.tar.xz"
# shellcheck disable=SC2034  # consumed by build_stage_05 inside installer.sh
STAGE6=( fake_6_01_A fake_6_02_B )

CALLS="$M/calls3"; : > "$CALLS"
build_run_lfs() { echo "$1" >> "$CALLS"; return 0; }

build_stage_05
check "first run builds both packages" "2" "$(wc -l < "$CALLS")"
build_stage_05
check "second run rebuilds nothing" "2" "$(wc -l < "$CALLS")"

# a changed source must invalidate exactly that package
printf 'A changed\n' > "$LFS/sources/fake-a.tar.xz"
build_stage_05
check "changed tarball rebuilds only that package" "3" "$(wc -l < "$CALLS")"
check "the rebuilt package was the changed one" "fake_6_01_A" "$(tail -1 "$CALLS")"

# a removed marker must force a rebuild
rm -f "$STAGEDIR"/*-pkgs/fake_6_02_B.done 2>/dev/null
build_stage_05
check "deleting a marker rebuilds that package" "4" "$(wc -l < "$CALLS")"

# the generated installer must expose the package->tarball map the marks use
nentry=$(grep -cE '^  \[build_[0-9]' "$LFS_ROOT/installer.sh")
if [ "$nentry" -ge 100 ]; then
    ok "installer.sh emits PKG_SRC for real packages ($nentry entries)"
else
    bad "installer.sh emits PKG_SRC for real packages" "only $nentry entries"
fi

echo "== 4. resume does not skip the chroot prologue, and clears old marks =="
# a) the non-resume clear must wipe the new per-package directories, not just
#    the top-level *.done files, or every package stays skipped forever.
if grep -qF 'rm -rf "${STAGEDIR:?}"/*' "$LFS_ROOT/installer.sh" \
   && ! grep -qF 'rm -f "$STAGEDIR"/*.done' "$LFS_ROOT/installer.sh"; then
    ok "non-resume run clears checkpoint subdirectories"
else
    bad "non-resume run clears checkpoint subdirectories" "old rm -f *.done still present"
fi

# b) the standalone dependency library must lint clean, not just the generated
#    file that happens to assign PKGS in the same scope.
if command -v shellcheck >/dev/null 2>&1; then
    sc=$(shellcheck -f gcc "$LFS_ROOT/regen/lib/deps.sh" 2>&1 | grep -c 'SC2153')
    check "deps.sh has no SC2153" "0" "$sc"
else
    echo "  skip shellcheck not installed"
fi

# c) stage 06's prologue (ownership fix + chroot prep) is outside the package
#    loop, so it must run on every attempt even when every package is skipped.
#    lfs_enter_chroot and chown are stubbed: this asserts the checkpoint logic
#    around them, not the chroot machinery.
# shellcheck source=/dev/null
source "$LFS_ROOT/installer.sh"
export STAGEDIR="$M/stages4" LOGDIR="$M/logs4" LFS="$M/lfs4"
rm -rf "$STAGEDIR" "$LOGDIR"; mkdir -p "$STAGEDIR" "$LOGDIR" "$LFS/sources"
printf 'A\n' > "$LFS/sources/fake-a.tar.xz"
declare -A PKG_SRC=()
# shellcheck disable=SC2034  # consumed by build_stage_06 inside installer.sh
PKG_SRC[fake_7_01_A]="fake-a.tar.xz"
# shellcheck disable=SC2034  # consumed by build_stage_06 inside installer.sh
STAGE7=( fake_7_01_A )
CALLS4="$M/calls4"; : > "$CALLS4"
chown() { echo "chown $*" >> "$CALLS4"; return 0; }
lfs_enter_chroot() { echo "chroot $*" >> "$CALLS4"; return 0; }

build_stage_06
build_stage_06
nprep=$(grep -c 'chroot-prep' "$CALLS4")
nbuild=$(grep -c 'build-one fake_7_01_A' "$CALLS4")
check "chroot-prep runs on every attempt" "2" "$nprep"
check "a checkpointed ch7 package builds once" "1" "$nbuild"

echo "== 5. the source tree is hashed once, not twice =="
# task_fetch_sources ran `md5sum -c md5sums` at the gate and then AGAIN only to
# count the OK lines: a second full read of the 629 MB source set for a number
# the first run had already produced. One capture now serves both.
nhash=$(grep -cF 'md5sum -c md5sums' "$LFS_ROOT/installer.sh")
check "the tree is hashed exactly once" "1" "$nhash"

echo "== 6. files with no md5 entry are not fetched =="
# Upstream's wget-list names a few files that have no md5sums entry
# (lfs-bootscripts among them, and that one 404s). Nothing in this script
# consumes them, so they must not be requested at all -- the old fetcher pulled
# them as best-effort "optional extras" and printed a warning every run.
# shellcheck source=/dev/null
source "$LFS_ROOT/installer.sh"
TREE3="$M/tree3"; PEAK3="$M/peak3"
mkdir -p "$TREE3"; : > "$TREE3/wget-list"; : > "$TREE3/md5sums"
for i in 1 2; do
    printf 'payload %s\n' "$i" > "$TREE3/pkg-$i.tar.xz"
    printf 'http://127.0.0.1:%s/pkg-%s.tar.xz\n' "$PORT" "$i" >> "$TREE3/wget-list"
    ( cd "$TREE3" && md5sum "pkg-$i.tar.xz" >> md5sums )
done
# present on the mirror, so an unfiltered fetcher would download it happily
printf 'extra\n' > "$TREE3/extra-unverified.tar.xz"
printf 'http://127.0.0.1:%s/extra-unverified.tar.xz\n' "$PORT" >> "$TREE3/wget-list"
start_mirror "$TREE3" "$PEAK3" || bad "mirror starts (section 6)" "see above"
export LFS="$M/lfs5"
mkdir -p "$LFS"
export LFS_DOWNLOAD_BASE="http://127.0.0.1:$PORT"
export -f task_fetch_sources
OUT3=$( timeout 60 bash -c task_fetch_sources 2>&1 ); RC3=$?
unset -f task_fetch_sources
unset LFS_DOWNLOAD_BASE
stop_mirror

check "fetch succeeds with an unverifiable file listed" "0" "$RC3"
if [ -f "$LFS/sources/extra-unverified.tar.xz" ]; then
    bad "an un-md5ed file is not downloaded" "extra-unverified.tar.xz landed"
else
    ok "an un-md5ed file is not downloaded"
fi
case "$OUT3" in
    *extra-unverified*) bad "an un-md5ed file is not requested" "named in output" ;;
    *)                  ok  "an un-md5ed file is not requested" ;;
esac
check "only the verified files landed" "2" "$(find "$LFS/sources" -maxdepth 1 -name 'pkg-*.tar.xz' | wc -l)"

printf '\npassed: %s\nfailed: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || { printf 'failed:%s\n' "$FAILED_NAMES"; exit 1; }
exit 0