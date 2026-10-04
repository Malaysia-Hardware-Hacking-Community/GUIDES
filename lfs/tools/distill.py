#!/usr/bin/env python3
import argparse
import html
import re
from collections import Counter
from pathlib import Path
from typing import NamedTuple


class Package(NamedTuple):
    name: str
    num: str        # e.g. "8.5.1"
    chapter: int    # 1-10
    blocks: list[str]


# any heading acts as a window boundary: sect2 (with optional anchor) or sect1 title
_SECT = re.compile(r'<h[23] class="(?:sect2|title)">\s*'
                   r'(?:<a[^>]*></a>)?\s*'
                   r'((?:\d+\.){2}\d+|(?:\d+\.)\d+|\d+|Chapter\s+\d+)?\.?'
                   r'([^<]*?)</h[23]>', re.S | re.I)
_KBD = re.compile(r'<kbd class=\s*"?command"?>(.*?)</kbd>', re.S | re.I)
_PRE = re.compile(r'<pre class="userinput">(.*?)</pre>', re.S | re.I)
_TAG = re.compile(r'<[^>]+>')
# A command line whose argument list ENDS in a bare `...` token is the book's
# own prose placeholder, not a runnable command. §8.23.1 GMP illustrates
# single-ABI builds as `ABI=32 ./configure ...` / `ABI=x86_64 ./configure ...`,
# where the ellipsis stands in for the reader's own options. Emitting it makes
# configure receive a literal `...` argument and abort with
# `machine '...-unknown' not recognized`. Only the trailing-ellipsis form is
# dropped, so genuine ellipses inside arguments (e.g. §8.23.1's
# `sed 's/()/(...)/' configure`) are preserved.
_PLACEHOLDER_CMD = re.compile(
    r'^\s*(?:[A-Za-z_][A-Za-z0-9_]*=\S+\s+)?(?:\./)?[A-Za-z0-9_.\-]+\s+\.\.\.\s*$')
# `exec` replaces the current shell. §8.39.1 Bash ends with `exec /usr/bin/bash
# --login` so an interactive builder continues in a fresh login shell that
# picks up the just-installed bash. Driven non-interactively that login bash has
# no script argument and inherits no usable stdin, so it dies with
# `line 1: script file read error: Bad file descriptor` -- and because it is an
# `exec`, it takes the whole driver shell with it, which no `||` guard can
# contain. The line is an interactive-shell convenience, not a build step, so it
# is dropped. Only 1 occurrence in the book.
_EXEC_SHELL = re.compile(r'^\s*exec\s+(?:/usr/bin/|/bin/)?(?:ba)?sh\b')
# §8.81.1 Util-linux embeds `bash tests/run.sh --srcdir=$PWD --builddir=$PWD`
# in the same <pre> as the real in-chroot suite (`touch /etc/fstab`, `chown -R
# tester .`, `su tester -c "make -k check"`), but the book's prose puts it in a
# different context: "If desired, this test can be run by booting into the
# completed LFS system and running: ...". It is a post-boot convenience, not a
# chroot build step, and it cannot pass in the chroot -- run.sh refuses to start
# ("Tests not compiled! Run 'make check-programs' to fix the problem."), the
# book warns the suite needs CONFIG_SCSI_DEBUG as a module in the *running*
# kernel, and states "For complete coverage, other BLFS packages must be
# installed". Kept out of the build; the in-chroot `make -k check` stays.
# Verified unique: 1 occurrence of tests/run.sh and 1 of the
# "booting into the completed LFS system" sentence in the whole book.
_POSTBOOT_ONLY = re.compile(r'^\s*bash\s+tests/run\.sh\b')
# The book also documents options with an angle-bracket placeholder, e.g.
# §8.64.1 Groff: `PAGE=<paper_size> ./configure --prefix=/usr`, where the prose
# above it says PAGE=letter for the US and PAGE=A4 elsewhere. Emitting the line
# hands bash an input redirect from a file named `paper_size` (and would
# redirect stdout onto ./configure), so the block dies with
# `paper_size: No such file or directory`. The COMMAND is real, so the
# placeholder assignment prefix is stripped and `./configure --prefix=/usr` is
# kept -- the book leaves PAGE at its default (letter) when unset. Matched only
# in assignment-value position (`VAR=<placeholder>`); the book contains no other
# angle-bracket use in a command line.
_ANGLE_PLACEHOLDER = re.compile(
    r'^(\s*)(?:[A-Za-z_][A-Za-z0-9_]*=\s*<[A-Za-z_][A-Za-z0-9_.\-]*>\s+)(.*)$')


def _split_pre(pre: str) -> list[str]:
    """Split a pre block into its command children; each cleaned block."""
    kbds = _KBD.findall(pre)
    if not kbds:
        return []
    out = []
    for k in kbds:
        text = _TAG.sub("", k)               # strip residual markup
        text = html.unescape(text).replace("\r", "")
        text = text.strip("\n").replace("\t", "    ")
        if not text:
            continue
        if any(_PLACEHOLDER_CMD.match(l) for l in text.splitlines()):
            continue                      # book prose placeholder, not a command
        lines = []
        for l in text.splitlines():
            if _POSTBOOT_ONLY.match(l):    # book says: run this after booting
                continue
            ap = _ANGLE_PLACEHOLDER.match(l)   # VAR=<placeholder> cmd ...
            if ap:
                l = ap.group(1) + ap.group(2)  # keep the real command
            lines.append(l)
        if not lines:
            continue
        text = "\n".join(lines)
        kept = [l for l in text.splitlines() if not _EXEC_SHELL.match(l)]
        if len(kept) != len(text.splitlines()):
            if not kept:
                continue                  # block was only the exec line
            text = "\n".join(kept)
        out.append(text)
    return out


def _heading_num_and_title(m) -> tuple[str, str]:
    # strip any embedded tags + entities from the captured title text
    title = html.unescape(_TAG.sub("", m.group(2))).strip()
    # fall back: if the optional number group missed (e.g. whitespace inside),
    # re-extract a leading "N.N.N. " prefix from the title
    mnum = re.match(r'((?:\d+\.){2}\d+)\.\s*(.*)$', title, re.S)
    if mnum:
        return mnum.group(1), mnum.group(2)
    return m.group(1) or "", title


def parse_packages(book_html: str) -> list[Package]:
    sections = list(_SECT.finditer(book_html))
    # windows end at the next heading of ANY kind (sect1 h2 title or sect2 h3)
    ends = [s.start() for s in sections[1:]] + [len(book_html)]
    packages: list[Package] = []
    for i, s in enumerate(sections):
        num, title = _heading_num_and_title(s)
        if not title.startswith("Installation of"):
            continue
        name = title[len("Installation of"):].strip()
        chapter = int(num.split(".")[0]) if num else 0
        window = book_html[s.end():ends[i]]
        blocks: list[str] = []
        for pre in _PRE.findall(window):
            blocks.extend(_split_pre(pre))
        packages.append(Package(name, num, chapter, blocks))
    return packages


def extract_book(path: str | Path) -> list[Package]:
    return parse_packages(Path(path).read_text(encoding="utf-8"))


def _main() -> None:
    ap = argparse.ArgumentParser(description="Extract LFS install commands from book HTML")
    ap.add_argument("book", nargs="?",
                    default=str(Path(__file__).resolve().parent.parent
                                / "book-13.1-nochunks.html"))
    ap.add_argument("--emit", action="store_true",
                    help="print the generated bash functions file")
    args = ap.parse_args()
    pkgs = extract_book(args.book)
    if args.emit:
        try:                             # package-relative (module invocation)
            from .render import render_all   # implemented in Task 2
        except ImportError:              # script invocation (python3 distill.py)
            from render import render_all
        print(render_all(pkgs), end="")
    else:
        print(f"{len(pkgs)} packages")
        print(dict(sorted(Counter(p.chapter for p in pkgs).items())))


if __name__ == "__main__":
    _main()
