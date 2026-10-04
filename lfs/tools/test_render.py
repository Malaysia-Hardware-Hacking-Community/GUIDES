from pathlib import Path

import render
from distill import Package

def test_func_name_namespaced_by_section():
    assert render.func_name(Package("Glibc", "8.5.1", 8, ["x"])) == "build_8_5_1_Glibc"
    assert render.func_name(Package("Glibc", "5.5.1", 5, ["x"])) == "build_5_5_1_Glibc"
    assert render.func_name(Package("Python 3", "8.54.1", 8, ["x"])) == "build_8_54_1_Python_3"

def test_render_package_unpacks_and_runs():
    p = Package("Bzip2", "8.7.1", 8, ["./configure --prefix=/usr", "make"])
    out = render.render_package(p)
    assert "SOURCES_DIR=\"${SOURCES_DIR:-/mnt/lfs/sources}\"" in out
    assert "tar -xf bzip2-1.0.8.tar.gz" in out
    assert 'pushd "$SOURCES_DIR"' in out
    assert "set -e" in out

def test_render_package_emits_case_verbatim():
    p = Package("Zlib", "8.6.1", 8, ["case $(uname -m) in\n x86_64) :\n esac"])
    out = render.render_package(p)
    assert "case $(uname -m) in" in out

def test_tcl_src_dir_name():
    p = Package("Tcl", "8.17.1", 8, ["cd unix", "./configure"])
    out = render.render_package(p)
    assert "tar -xf tcl8.6.18-src.tar.gz" in out
    assert "pushd tcl8.6.18" in out
    assert "tcl8.6.18-src" not in out.replace("tcl8.6.18-src.tar.gz", "")

def test_uefi_grup_skipped():
    assert render.render_package(Package("GRUB for 64-bit UEFI", "8.65.2", 8, ["make"])) == ""
    assert render.render_package(Package("GRUB for 32-bit UEFI", "8.65.3", 8, ["make"])) == ""

def test_grub_configure_picks_platform_from_firmware():
    # §8.65.1 is BIOS-only; a UEFI chroot built from it has no
    # /usr/lib/grub/x86_64-efi and task_bootable's grub-install --target
    # x86_64-efi dies after chapter 8. Both platform configures must be here.
    p = Package("GRUB for BIOS", "8.65.1", 8,
                ["./configure --prefix=/usr \\\n --sysconfdir=/etc \\\n --disable-efiemu  \\\n --disable-werror",
                 "make", "make install"])
    out = render.render_package(p)
    assert 'case "${LFS_FIRMWARE:-bios}" in' in out
    assert out.count("./configure --prefix=/usr") == 2
    # the UEFI branch carries §8.65.2's platform flags ...
    uefi_branch = out.split("uefi)", 1)[1].split(";;", 1)[0]
    assert "--with-platform=efi" in uefi_branch and "--target=x86_64" in uefi_branch
    # ... and the book's own options survive on both branches
    assert out.count("--disable-efiemu") == 2
    assert out.count("--disable-werror") == 2
    assert "make install" in out and "make install ||" not in out

def test_grub_platform_substitution_needs_exactly_one_configure():
    # Two ./configure blocks would mean the substitution picked one at random.
    p = Package("GRUB for BIOS", "8.65.1", 8, ["./configure --prefix=/usr", "./configure"])
    try:
        render.render_package(p)
    except SystemExit as e:
        assert "exactly one ./configure" in str(e), e
    else:
        raise AssertionError("two ./configure blocks were accepted")

def test_render_all_counts_and_stage_arrays():
    pkgs = [
        Package("Glibc", "5.5.1", 5, ["make"]),
        Package("Bzip2", "8.7.1", 8, ["make"]),
        # the real §8.65.1 has a ./configure; the platform substitution
        # requires one and refuses to guess without it
        Package("GRUB for BIOS", "8.65.1", 8, ["./configure --prefix=/usr", "make"]),
        Package("GRUB for 64-bit UEFI", "8.65.2", 8, ["make"]),
        Package("the kernel", "10.3.1", 10, ["make"]),   # excluded (ch10)
    ]
    out = render.render_all(pkgs)
    assert out.count("() {") == 3          # 5.5.1, 8.7.1, 8.65.1 (UEFI + kernel skipped)
    assert "STAGE5=( build_5_5_1_Glibc )" in out
    assert "STAGE8=( build_8_7_1_Bzip2 build_8_65_1_GRUB_for_BIOS )" in out
    assert "STAGE10" not in out

import distill, render, os
# Default to the book checked into the repo, the same input regen/assemble.py
# distils. It used to point into a scratch directory, so wiping that
# directory silently broke this suite while the installer still assembled
# fine -- two halves of the toolchain disagreed about where the book was.
BOOK = os.environ.get(
    "LFS_BOOK",
    str(Path(__file__).resolve().parent.parent / "book-13.1-nochunks.html"),
)

def test_full_book_coverage():
    pkgs = distill.extract_book(BOOK)
    out = render.render_all(pkgs)
    body = out[: out.index("\nSTAGE8=")]
    ch8 = [p for p in pkgs if p.chapter == 8]
    built = [p for p in ch8 if p.name not in render.SKIPPED]
    for p in built:
        assert render.func_name(p) in body, f"missing {p.name} ({p.num})"
    assert len(built) == 80                     # 82 - 2 UEFI
    assert len(out.split("() {")) - 1 == 110    # 5+17+8+80

def test_expect_heredoc_test_guard_keeps_terminator_bare():
    # §8.39.1 Bash drives its suite via `su -s expect tester << "EOF"`. The
    # guard must land on the FIRST line: a `<<` terminator line has to stay
    # exactly the delimiter word or the heredoc never terminates.
    html = ('<h3 class="sect2">8.39.1. Installation of Bash</h3>'
            '<pre class="userinput"><kbd class="command">make</kbd>'
            '<kbd class="command">LC_ALL=C.UTF-8 su -s /usr/bin/expect tester &lt;&lt; "EOF"\n'
            'set timeout -1\nspawn make tests\nexpect eof\nEOF</kbd>'
            '<kbd class="command">make install</kbd></pre>')
    p = distill.parse_packages(html)[0]
    body = render.render_package(p)
    lines = body.splitlines()
    guard = [l for l in lines if 'su -s /usr/bin/expect' in l]
    assert len(guard) == 1, lines
    assert guard[0].rstrip().endswith('(book: failures non-fatal)"; }')
    # the terminator is still a bare EOF, with no guard appended to it
    assert [l.strip() for l in lines if l.strip() == 'EOF'], lines
    assert 'EOF ||' not in body
    # sibling build steps stay fatal
    assert 'make install' in body and 'make install ||' not in body

def test_systemd_meson_test_nonfatal_but_os_release_fatal():
    # §8.77.1: "Three tests are known to fail in the LFS chroot environment but
    # pass in a full installation". The test must not abort the build, but the
    # os-release echo sharing the block is a real setup step and stays fatal.
    html = ('<h3 class="sect2">8.77.1. Installation of systemd</h3>'
            '<pre class="userinput"><kbd class="command">'
            'echo \'NAME="Linux From Scratch"\' &gt; /etc/os-release\n'
            'unshare -m ninja test</kbd></pre>')
    p = distill.parse_packages(html)[0]
    blocks = render._tolerate(p)
    lines = blocks[0].split("\n")
    assert lines[0] == 'echo \'NAME="Linux From Scratch"\' > /etc/os-release'
    assert lines[1].startswith("unshare -m ninja test || {")
    assert "3 tests known to fail" in lines[1]

def test_meson_test_pattern_is_exact():
    # A real `ninja` build step must never be mistaken for the test command.
    for line in ("ninja", "ninja test", "unshare -m ninja", "unshare -n ninja test"):
        assert not render._MESON_TEST.match(line), line
    assert render._MESON_TEST.match("unshare -m ninja test")


# --- standalone runner -----------------------------------------------------
# pytest is not installed in this environment (and may not be), but the plan
# documents `python3 test_render.py` / `python3 test_distill.py` as the command.
# Without this block those commands define the test functions, run nothing and
# exit 0 -- a false pass. The block keeps the file valid under pytest as well.
#
# THIS BLOCK MUST BE THE LAST THING IN THE FILE. It introspects globals() when
# the module finishes executing, so a test appended below it is silently never
# run -- the file still reports 10/10 and exits 0. That was verified by
# inserting a failing test after this block (reported 10/10, exit 0) and again
# before it (reported 10/11, exit 1).

def test_gmp_pass_count_never_blocks_or_kills_the_stage():
    # §8.23.1 GMP closes its suite with an informational pass count:
    #     cat $(find -name '*.log') | grep -c ^PASS
    # Two hazards the grep-shaped rule cannot see, because this line starts with
    # cat rather than grep and so never matched _FAILGREP:
    #   1. If find matches nothing the substitution expands to zero words and
    #      `cat` is left with no operands, so it reads stdin -- the installer's,
    #      i.e. the operator's console. An unattended build sits there forever.
    #   2. `grep -c` exits 1 when the count is zero, and under the stage's
    #      `set -e` that kills a stage whose `make check` failure the line above
    #      just declared non-fatal.
    # Fixing it with `|| true` alone would not help: the hang happens before the
    # guard is ever consulted, so the find has to stop feeding cat directly.
    # Commands are separate <kbd>s because that is how the book marks them up,
    # and it matters: _tolerate puts the suite guard on a block's LAST line, so
    # collapsing them into one block would move the guard onto `make install`
    # and test something the book never says.
    html = ('<h3 class="sect2">8.23.1. Installation of GMP</h3>'
            '<pre class="userinput"><kbd class="command">./configure --prefix=/usr</kbd>'
            '<kbd class="command">make check</kbd>'
            "<kbd class=\"command\">cat $(find -name '*.log') | grep -c ^PASS</kbd>"
            '<kbd class="command">make install</kbd></pre>')
    p = distill.parse_packages(html)[0]
    blocks = render._tolerate(p)

    summary = [l for b in blocks for l in b.split("\n") if 'grep -c' in l]
    assert len(summary) == 1, blocks
    line = summary[0]
    # cat must be fed by find, never left to read stdin
    assert '-exec cat {} +' in line, line
    assert not line.split('|')[0].strip().startswith('cat'), line
    # and the count may not end the stage
    assert line.rstrip().endswith('|| true'), line

    # the suite guard belongs on make check, and make install stays fatal
    check = [b for b in blocks if 'make check' in b]
    assert len(check) == 1 and 'failures non-fatal' in check[0], blocks
    install = [b for b in blocks if 'make install' in b]
    assert install == ['make install'], blocks

def test_grep_of_find_logs_cannot_read_the_console():
    # §8.5.1 Glibc and §8.22.1 Binutils end their suites with a diagnostic grep
    # over the logs, exactly as §8.23.1 GMP ends with a count:
    #     grep "Timed out" $(find -name \*.out) || true
    # `|| true` already covers the exit status, so these look safe. They are not:
    # if find matches nothing the substitution expands to zero words and grep is
    # left with no file operands, so it reads stdin -- the operator's console --
    # and the stage hangs there. The guard is only consulted once grep returns,
    # which on a console is whenever the operator types a line. Same hazard, same
    # fix: find feeds cat through -exec, so the pipe is never empty at its head.
    html = ('<h3 class="sect2">8.5.1. Installation of Glibc</h3>'
            '<pre class="userinput"><kbd class="command">'
            "grep \"Timed out\" $(find -name \\*.out) || true</kbd></pre>")
    p = distill.parse_packages(html)[0]
    blocks = render._tolerate(p)
    assert len(blocks) == 1, blocks
    line = blocks[0]
    assert '-exec grep -H' in line, line
    assert line.strip().startswith('find '), line
    assert '$(find' not in line, line
    # the guard must survive the rewrite, and appear exactly once
    assert line.rstrip().endswith('|| true'), line
    assert line.count('|| true') == 1, line
    # -H keeps the filename prefix, which is how the reader learns which log
    # timed out; cat-into-a-pipe would silently drop it
    assert 'grep -H "Timed out" {} +' in line, line


def test_book_substitutions_are_quoted_where_quoting_is_safe():
    # The book writes `--build=$(./config.guess)`, `$(gcc -print-libgcc-file-name)`
    # and friends unquoted. Each expands to a single path with no spaces, so
    # quoting changes nothing about what runs -- it only removes the possibility
    # that the shell re-splits or globs the result. Quoting a value that is
    # already a single token is free; leaving it unquoted is a latent trap.
    cases = [
        ('./configure --build=$(./config.guess)',
         './configure --build="$(./config.guess)"'),
        ('DIR=$(dirname $(gcc -print-libgcc-file-name))',
         'DIR=$(dirname "$(gcc -print-libgcc-file-name)")'),
        ('ln -sfvr $(gcc -print-prog-name=liblto_plugin.so) /usr/lib/bfd-plugins/',
         'ln -sfvr "$(gcc -print-prog-name=liblto_plugin.so)" /usr/lib/bfd-plugins/'),
    ]
    html = ('<h3 class="sect2">8.99.1. Installation of Quote</h3>'
            '<pre class="userinput">'
            + ''.join('<kbd class="command">%s</kbd>' % c.replace('&', '&amp;')
                      for c, _ in cases)
            + '</pre>')
    p_ = distill.parse_packages(html)[0]
    blocks = render._tolerate(p_)
    for (_src, want), got in zip(cases, blocks):
        assert got == want, (got, want)
    # already-quoted substitutions are left exactly as they are
    assert not render._SUBST_TO_QUOTE.search('grep "$(id -u)" f'), 'idempotence'


def test_escaped_find_globs_are_single_quoted():
    # `-name \*.so*` is the book's way of passing a glob to find unexpanded.
    # Single quotes say the same thing without the backslashes, so the shell
    # cannot misread them as an escaped literal.
    assert render._ESCAPED_GLOB.sub(r"-name '\1'", r'for i in $(find /usr/lib -name \*.so*)') \
        == "for i in $(find /usr/lib -name '*.so*')"
    assert render._ESCAPED_GLOB.sub(r"-name '\1'", r'! -name \*dbg') == "! -name '*dbg'"
    # a -name with no escaped glob is untouched
    assert render._ESCAPED_GLOB.search('find . -name plain') is None


def test_find_pipe_xargs_rm_becomes_exec():
    # `find ... | xargs rm -rf` runs rm zero times when find matches nothing,
    # which is fine, but xargs splits on whitespace and newlines, so a path with
    # a space becomes two arguments and rm is handed a path that does not exist
    # next to one that does. -exec passes the same arguments as one batch.
    html = ('<h3 class="sect2">8.98.1. Installation of Xargs</h3>'
            '<pre class="userinput"><kbd class="command">'
            'find /usr -depth -name $(uname -m)*-lfs-linux-gnu\\* | xargs rm -rf'
            '</kbd></pre>')
    p_ = distill.parse_packages(html)[0]
    line = render._tolerate(p_)[0]
    assert 'xargs' not in line, line
    assert line.strip().endswith('-exec rm -rf {} +'), line
    assert line.strip().startswith('find '), line


def test_pass_count_pattern_needs_the_cat_pipe_shape():
    # A real cat of a log file is not the pass-count summary and must stay fatal.
    for line in ("cat foo.log", "cat $(find -name '*.log')",
                 "cat /usr/lib/libz.a", "make install"):
        assert not render._PASSCOUNT.match(line), line

if __name__ == "__main__":
    import sys as _sys
    import traceback as _tb

    _tests = [(n, o) for n, o in sorted(globals().items())
              if n.startswith("test_") and callable(o)]
    _failed = 0
    for _n, _f in _tests:
        try:
            _f()
            print(f"PASS {_n}")
        except Exception:
            _failed += 1
            print(f"FAIL {_n}")
            _tb.print_exc()
    print(f"\n{len(_tests) - _failed}/{len(_tests)} passed")
    _sys.exit(1 if _failed else 0)

