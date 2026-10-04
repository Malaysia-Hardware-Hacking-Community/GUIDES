import distill

SEC = '<h3 class="sect2">8.5.1. Installation of Glibc</h3>'

def test_parse_single_package_blocks():
    html = (SEC +
            '<pre class="userinput"><kbd class="command">case $(uname -m) in\n'
            '    x86_64) echo ok &gt;&gt; $LFS/lib64/result\n    ;;\n'
            'esac</kbd></pre>'
            '<pre class="userinput"><kbd class="command">echo &#34;hello&#34;</kbd></pre>')
    pkgs = distill.parse_packages(html)
    assert len(pkgs) == 1
    p = pkgs[0]
    assert (p.name, p.num, p.chapter) == ("Glibc", "8.5.1", 8)
    assert len(p.blocks) == 2
    assert 'case $(uname -m) in' in p.blocks[0]
    assert '    x86_64) echo ok >> $LFS/lib64/result' in p.blocks[0]
    assert '"hello"' in p.blocks[1]

def test_parser_ignores_non_command_pre():
    html = ('<h3 class="sect2">8.6.1. Installation of Zlib</h3>'
            '<pre>plain text fence</pre>'
            '<pre class="userinput"><kbd class="command">./configure --prefix=/usr</kbd></pre>')
    pkgs = distill.parse_packages(html)
    assert len(pkgs) == 1 and pkgs[0].blocks == ['./configure --prefix=/usr']

def test_whitespace_tolerant_kbd():
    html = ('<h3 class="sect2">8.7.1. Installation of Bzip2</h3>'
            '<pre class="userinput"><kbd class=\n "command">make</kbd></pre>')
    pkgs = distill.parse_packages(html)
    assert pkgs[0].blocks == ['make']

def test_window_stops_at_next_any_sect2():
    """Non-Installation subsections must NOT bleed into a package window."""
    html = ('<h3 class="sect2">8.5.1. Installation of Glibc</h3>'
            '<pre class="userinput"><kbd class="command">echo glibc-part-1</kbd></pre>'
            '<h3 class="sect2">8.5.2. nsswitch</h3>'
            '<pre class="userinput"><kbd class="command">echo config-file-here</kbd></pre>'
            '<h3 class="sect2">8.6.1. Installation of Zlib</h3>'
            '<pre class="userinput"><kbd class="command">./configure</kbd></pre>')
    pkgs = distill.parse_packages(html)
    assert len(pkgs) == 2
    assert pkgs[0].blocks == ['echo glibc-part-1']           # no bleed from 8.5.2
    assert pkgs[1].blocks == ['./configure']                  # no bleed from earlier

def test_anchor_bearing_sect2_is_a_boundary():
    """Anchor-bearing h3 (8.5.2 Configuring Glibc / 8.82.2) MUST be a boundary."""
    html = ('<h3 class="sect2">8.5.1. Installation of Glibc</h3>'
            '<pre class="userinput"><kbd class="command">echo glibc-part-1</kbd></pre>'
            '<h3 class="sect2">\n<a id="contents-glibc" name="contents-glibc">'
            '</a>8.5.3. Configuring Glibc</h3>'
            '<pre class="userinput"><kbd class="command">cat > /etc/nsswitch.conf</kbd></pre>'
            '<h3 class="sect2">8.6.1. Installation of Zlib</h3>'
            '<pre class="userinput"><kbd class="command">./configure</kbd></pre>')
    pkgs = distill.parse_packages(html)
    assert len(pkgs) == 2
    assert pkgs[0].blocks == ['echo glibc-part-1']           # anchor heading stops the window
    assert pkgs[1].blocks == ['./configure']

def test_h2_title_is_a_boundary():
    """sect1 h2 titles (ch7 7.2-7.6, chapter titles) MUST stop a package window."""
    html = ('<h3 class="sect2">6.18.1. Installation of GCC</h3>'
            '<pre class="userinput"><kbd class="command">make</kbd></pre>'
            '<h2 class="title">7.2. Changing Ownership</h2>'
            '<pre class="userinput"><kbd class="command">chown root:root foo   # ROOT-ONLY</kbd></pre>'
            '<h3 class="sect2">7.7.1. Installation of Gettext</h3>'
            '<pre class="userinput"><kbd class="command">./configure</kbd></pre>')
    pkgs = distill.parse_packages(html)
    assert len(pkgs) == 2
    assert pkgs[0].blocks == ['make']                        # chown never bleeds into GCC
    assert pkgs[1].blocks == ['./configure']

def test_multiple_kbd_children_split_into_blocks():
    html = ('<h3 class="sect2">5.4.1. Installation of Linux API Headers</h3>'
            '<pre class="userinput"><kbd class="command">make headers_install INSTALL_HDR_PATH=dest</kbd>'
            '<kbd class="command">cp -rv dest/include $LFS/usr</kbd></pre>')
    p = distill.parse_packages(html)[0]
    assert p.blocks == ['make headers_install INSTALL_HDR_PATH=dest',
                        'cp -rv dest/include $LFS/usr']

def test_raw_em_tags_stripped():
    html = ('<h3 class="sect2">8.23.1. Installation of GMP</h3>'
            '<pre class="userinput"><kbd class="command">ABI=32 ./configure <em class="filename">--enable-cxx</em></kbd></pre>')
    p = distill.parse_packages(html)[0]
    assert p.blocks[0] == 'ABI=32 ./configure --enable-cxx'

def test_prose_placeholder_command_dropped():
    # The book illustrates single-ABI GMP builds as `ABI=32 ./configure ...`,
    # where the ellipsis stands in for the reader's own options. Emitting it
    # makes configure abort with "machine '...-unknown' not recognized".
    html = ('<h3 class="sect2">8.23.1. Installation of GMP</h3>'
            '<pre class="userinput">'
            '<kbd class="command">ABI=32 ./configure ...</kbd>'
            '<kbd class="command">ABI=x86_64 ./configure ...</kbd>'
            '<kbd class="command">./configure --prefix=/usr</kbd></pre>')
    p = distill.parse_packages(html)[0]
    assert p.blocks == ['./configure --prefix=/usr']

def test_ellipsis_inside_arguments_is_kept():
    # Only a TRAILING bare `...` is a placeholder; ellipses inside a command's
    # arguments are real content (GMP's sed patch for 32-bit time_t).
    html = ('<h3 class="sect2">8.23.1. Installation of GMP</h3>'
            '<pre class="userinput">'
            "<kbd class=\"command\">sed -i '/long long t1;/,+1s/()/(...)/' configure</kbd>"
            '<kbd class="command">ABI=32 ./configure ...</kbd></pre>')
    p = distill.parse_packages(html)[0]
    assert p.blocks == ["sed -i '/long long t1;/,+1s/()/(...)/' configure"]

def test_exec_shell_line_dropped():
    # §8.39.1 Bash ends with `exec /usr/bin/bash --login` so an interactive
    # builder gets a fresh login shell. Non-interactively that login bash has no
    # script argument and no usable stdin, and being an `exec` it would take the
    # whole driver shell with it. The line is an interactive convenience, not a
    # build step, so it is dropped.
    html = ('<h3 class="sect2">8.39.1. Installation of Bash</h3>'
            '<pre class="userinput">'
            '<kbd class="command">make install</kbd>'
            '<kbd class="command">exec /usr/bin/bash --login</kbd></pre>')
    p = distill.parse_packages(html)[0]
    assert p.blocks == ['make install']

def test_exec_shell_dropped_without_losing_siblings():
    # A block that mixes the exec with real work keeps the real work.
    html = ('<h3 class="sect2">8.39.1. Installation of Bash</h3>'
            '<pre class="userinput"><kbd class="command">make install\nexec /usr/bin/bash --login\n'
            'echo after</kbd></pre>')
    p = distill.parse_packages(html)[0]
    assert p.blocks == ['make install\necho after']

def test_angle_placeholder_prefix_stripped_not_block_dropped():
    # §8.64.1 Groff: `PAGE=<paper_size> ./configure --prefix=/usr`. The prose
    # above says PAGE=letter (US) / PAGE=A4 (elsewhere). Emitted verbatim, bash
    # reads `<paper_size>` as an input redirect from a file named paper_size and
    # dies with "No such file or directory". The command itself is real, so the
    # placeholder prefix is stripped and configure survives.
    html = ('<h3 class="sect2">8.64.1. Installation of Groff</h3>'
            '<pre class="userinput"><kbd class="command">PAGE=&lt;paper_size&gt; '
            './configure --prefix=/usr</kbd></pre>')
    p = distill.parse_packages(html)[0]
    assert p.blocks == ['./configure --prefix=/usr']

def test_angle_placeholder_only_stripped_in_assignment_position():
    # A stray `<foo>` that is not an assignment value must not be touched.
    html = ('<h3 class="sect2">8.64.1. Installation of Groff</h3>'
            '<pre class="userinput"><kbd class="command">echo a &lt; b &gt; c</kbd></pre>')
    p = distill.parse_packages(html)[0]
    assert p.blocks == ['echo a < b > c']

def test_postboot_only_run_sh_dropped():
    # §8.81.1 Util-linux: the book says "If desired, this test can be run by
    # booting into the completed LFS system and running: bash tests/run.sh ...".
    # In the chroot run.sh cannot pass ("Tests not compiled!"), so it is a
    # post-boot step and is dropped.
    html = ('<h3 class="sect2">8.81.1. Installation of Util-linux</h3>'
            '<pre class="userinput"><kbd class="command">'
            'bash tests/run.sh --srcdir=$PWD --builddir=$PWD</kbd></pre>')
    p = distill.parse_packages(html)[0]
    assert p.blocks == []

def test_util_linux_chroot_suite_survives_postboot_removal():
    # The real in-chroot steps share the subsection and must not be collateral
    # damage from dropping the post-boot run.sh line.
    html = ('<h3 class="sect2">8.81.1. Installation of Util-linux</h3>'
            '<pre class="userinput"><kbd class="command">touch /etc/fstab\n'
            'chown -R tester .\nsu tester -c "make -k check"</kbd></pre>')
    p = distill.parse_packages(html)[0]
    assert p.blocks == ['touch /etc/fstab\nchown -R tester .\nsu tester -c "make -k check"']


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
