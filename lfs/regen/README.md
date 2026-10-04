# regen — how `installer.sh` is assembled

Nothing in here is used at runtime. `installer.sh` is the deliverable and it
stands alone: it reads no sidecar files, and it does not source anything from
this directory.

```bash
python3 regen/assemble.py     # rewrites ../installer.sh in place
```

## How it works

`installer.sh` is the result of splicing together `regen/lib/*.sh` and
rewriting only the seams between them — the places where one of the original
scripts used to `source` another, shell out to a sibling, or read a package
table from `pkgmgr/*.conf`. Everything else is copied verbatim, which is the
point: the split files stayed readable, and the merge stayed auditable.

The build stages and the task functions were converted the same way, from
separate scripts into functions in one file, so that `--internal <task>` can
re-enter the file from inside the chroot.

## The book section

The 110 package build functions are not in `lib/`. They are distilled from
`../book-13.1-nochunks.html` by `../tools/distill.py` and rendered into shell by
`../tools/render.py`, and the assembler imports both and inlines the result.

This runs on every assembly, so editing the book or the renderer and re-running
updates the installer. The emitted text is byte-for-byte what
`tools/distill.py --emit` writes, minus its shebang and its global `set -u` —
both of which are wrong in context, and the second of which would silently
re-enable nounset in every caller that sources the installer.

The section is delimited by two marker comments so the installer can re-extract
it for the build children:

```bash
source ../installer.sh
book_emit | head                    # the section, as the children receive it
book_function build_8_24_1_MPFR     # just one of them
```

The children run with `env -i` and therefore cannot source the parent, so this is
how chapter 5-6 and the chapter 7-8 chroot entries get their function
definitions. `build_run_lfs` writes the section to a temp file, `chmod 0644`s
it, and passes the path — it does not pipe it in, because `/dev/stdin` is
`/proc/self/fd/0` and a child that dropped privileges to `lfs` cannot reopen a
root-owned pipe through procfs. The file is removed when the package returns. `task_build_one` (reached as `--internal build-one <name>`) checks
the name against the functions actually present in the file rather than trusting
it, because the name arrives from a stage array one shell away from that array's
own definition.

## Never hand-edit the book section

Everything between the two `BOOK_FUNCS` markers is overwritten on every
assembly. Change `../book-13.1-nochunks.html`, `../tools/render.py`, or
`regen/lib/deps.sh` and re-run. A hand-edit is not an error the assembler will
catch — it is just gone next time.

## What the assembler refuses to do

It asserts rather than emitting something plausible. It fails if:

- the distiller's output no longer starts with the header it expects to strip
- a stage list names a function that is not there — the build would otherwise
  fail with "command not found" hours in
- a splice seam is not found, meaning a source file was restructured
- an include guard leaks into the output, which would break double-sourcing
- the generated function count changes, reported loudly though not fatal, since
  it is expected to move when the book changes
