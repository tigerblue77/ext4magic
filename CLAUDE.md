# CLAUDE.md

ext4magic recovers deleted files from ext2/ext3/ext4 by reading old inode copies
out of the filesystem journal. It is a C program built with autotools, forked
from Roberto Maar's 0.3.2 BETA.

This file holds what is **not** written down elsewhere. Everything that already
has a document is linked rather than copied :

| For | Read |
| --- | --- |
| What the program does, its options, its known bugs | [`README`](README) sections 1 to 7 |
| Building and installing, and the special cases | [`INSTALL`](INSTALL), [`INSTALL.de`](INSTALL.de) |
| The manual page | [`src/ext4magic.8`](src/ext4magic.8) |
| The test suite : what it covers, what it deliberately does not, how to add a case | [`tests/README.md`](tests/README.md) |
| What CI runs, and why it runs it twice | [`.github/workflows/tests.yml`](.github/workflows/tests.yml) |
| History | [`ChangeLog`](ChangeLog), [`NEWS`](NEWS), [`TODO`](TODO) |

## Build and test

```bash
./configure && make          # produces src/ext4magic
./tests/run_tests.sh         # the whole suite, both kinds of test case
```

`tests/README.md` lists the runner's other options. The two that matter outside
CI are `--list` and `-f PATTERN`, and `EXT4MAGIC_BINARY` points the suite at a
binary built elsewhere.

Run the suite as **root**. Below root it still passes, but 115 of its 260 cases
skip — see `tests/README.md`, "Run it as root", for why that is about ext4magic
rather than about the suite.

Reference numbers on a clean checkout of `master`, measured in a session
container :

| Run | Result |
| --- | --- |
| `./tests/run_tests.sh` as root | `260 test cases passed (940 assertions)`, exit 0, about 7 minutes |
| `./tests/run_tests.sh` unprivileged | `145 test cases passed, 115 skipped (625 assertions)`, exit 0 |

Both are CI gates, and CI runs no other check : **there is no linter and no
formatter in this repository.** The shell sources carry `# shellcheck disable=`
directives, so shellcheck is clearly run by hand, but no bar is enforced —
`shellcheck -x -S error` over `tests/` is clean, `-S warning` reports 7 and
`-S style` reports 16. Do not add a lint gate as a side effect of another
change — whether one should exist at all is issue #48.

## What CI needs that a fresh container does not have

The workflow installs `build-essential autoconf automake libtool libext2fs-dev
comerr-dev libmagic-dev libblkid-dev uuid-dev zlib1g-dev libbz2-dev e2fsprogs`.
On the Ubuntu 24.04 image these sessions start from, three of those are missing :
**`libext2fs-dev`** (`ext2fs/ext2fs.h`, `e2p/e2p.h`), **`comerr-dev`** and
**`libmagic-dev`** (`magic.h`). Without them `./configure` stops at
`You must install the develop packages "ext2fs , blkid , e2p , uuid"`.

[`.claude/hooks/session-start.sh`](.claude/hooks/session-start.sh) installs them
at session start, so this should already be done. Its package list is a copy of
the workflow's, and nothing keeps the two in step — issue #47. It is best effort : if it
prints a failure on stderr, install them by hand before trying to build.

The hook does **not** build the tree. Run `./configure && make` yourself — and
read the first invariant below before you look at `git status` afterwards.

## Layout

Everything the program is made of is in `src/`, one flat directory :

| File | What it does |
| --- | --- |
| `ext4magic.c` | `main()`, option parsing, the mode dispatch, and the `-S` superblock report |
| `journal.c` | Opens the journal (internal or external), maps journal blocks to filesystem blocks, and the `-J` / `-T` reports |
| `inode.c` | Reads inodes out of journal copies, and the `-I` dump |
| `block.c` | Block iteration : indirect, double and triple indirect, plus a private extent handle |
| `recover.c` | Writes a recovered file out : data blocks, symlinks, mode, owner, attributes |
| `lookup_local.c` | Resolves a path and lists a directory, from live blocks and from journal copies |
| `dir_list.c` | The directory rebuilt out of old journal blocks |
| `imap_search.c` | Finds inodes through the inode bitmap when no directory entry survives |
| `magic_block_scan.c` | The `-m` / `-M` scan engine : the three passes |
| `file_type.c` | The signature table the scan carves with — 8894 lines, and by far the largest file |
| `extent_db.c` | The ext4 extent cache the scan collects into |
| `hard_link_stack.c` | Turns several names on one inode into links rather than copies |
| `ring_buf.c` | The ring of journal inode copies a recovery chooses from |
| `util.c` | Time, inode mode, hexdump, `parse_ulong`, `reset_getopt` |
| `ext2fsP.h`, `kernel-jbd.h`, `kernel-list.h`, `jfs_*.h` | Copies of libext2fs and kernel JBD2 internals — see the invariants |

Local include edges, which is the whole of the coupling :

```
ext4magic.c  -> util.h ext4magic.h journal.h inode.h hard_link_stack.h block.h
journal.c    -> jfs_user.h ext4magic.h util.h journal.h inode.h
imap_search.c-> util.h inode.h magic.h journal.h block.h hard_link_stack.h
lookup_local.c-> ext2fsP.h dir_list.h util.h inode.h block.h
magic_block_scan.c -> util.h inode.h magic.h extent_db.h
recover.c    -> util.h hard_link_stack.h inode.h block.h
inode.c      -> inode.h ring_buf.h extent_db.h block.h
block.c      -> ext2fsP.h block.h journal.h util.h
util.c       -> util.h ext2fsP.h block.h inode.h
file_type.c  -> util.h inode.h
dir_list.c, extent_db.c, hard_link_stack.c, ring_buf.c -> their own header only
```

Those last four have no other local dependency, which is why they are the four
data structures the unit tests can link on their own. `tests/unit/build.sh`
compiles `util.c ring_buf.c dir_list.c extent_db.c hard_link_stack.c
file_type.c` from `src/` — adding a translation unit to a unit test means adding
it to `SOURCES_UNDER_TEST` there and its globals to `tests/unit/stubs.c`.

`tests/` has its own layout section in `tests/README.md`.

## Conventions

- **Commit messages.** A one line summary in the imperative, then a body in
  prose that says *why* and what was measured. Look at `git log` before writing
  one : the recent history is the standard. An `area:` prefix (`journal:`,
  `block:`, `tests:`) where the change is confined to one, none where it is not.
  **No `Signed-off-by`** — there is no DCO here, and no commit in the history
  carries one. Do not start.
- **Branches.** `fix/…` for a defect, `chore/…` for a change with no behavioural
  effect, `tests/…` for the suite. One issue, one branch, one pull request.
- **Issues.** They are the design record here, not a bug queue : they carry the
  measurement, the options considered and what was rejected. Cite the number in
  the code and in the commit when you touch something an issue covers.
- **License headers.** Every `src/*.c` and `src/*.h` file that is original to
  ext4magic opens with the GPL-2-or-later block naming Roberto Maar. Keep it on
  files you edit, and copy it onto any new C file. The files lifted from libmagic,
  libext2fs and the kernel keep *their* header instead. **Shell scripts carry no
  license header** — `tests/*.sh` open with a shebang and a prose comment
  explaining what the file is for, and so should any new one.
- **Shell style**, as in `tests/` : `#!/bin/bash`, two space indent,
  `function name() {`, `local -r` with uppercase names, `printf` rather than
  `echo`, and comments that explain the reasoning rather than restating the code.
  `set -u` where it is used at all; the repository does not use `set -e`.
- **The C is old and inconsistent** — tabs, `k&r`-ish braces, German comments in
  places. Match the file you are in, do not reformat around your change.
- **Prose in this repository puts a space before `:` and `;`.** It is
  consistent across `README`, `tests/README.md` and the recent commit bodies.

## Non-obvious invariants

Things that look like a defect and are not, or are a defect the tree
deliberately still carries. Each cost something to establish — check the issue
before you undo one.

### `make` rewrites two tracked files. Never `git add -A` after a build

`./configure && make` leaves `configure` (+2605/−2138 lines) and `config.h.in`
modified in the working tree. It happens on the first build of a fresh clone,
every time, and again whenever the mtimes fall back out of order :

```console
$ git status --porcelain
 M config.h.in
 M configure
```

Automake's rebuild rules fire because git does not preserve mtime ordering
between `configure.ac` and `aclocal.m4`, and the shipped automake-1.12 era
`missing` script *touches* `aclocal.m4`, confirming the decision. It only bites
people who have autoconf installed — which is every session container.

Recover with `git checkout -- configure config.h.in`, and never stage with
`git add -A` or `git commit -a` in this repository. **Issue #34**, which also
records why regenerating everything and why dropping the generated files were
both rejected; **PR #35** proposes `AM_MAINTAINER_MODE`.

### `extent_errout:` in `block.c` runs on success, and the obvious fix corrupts data

`src/block.c:697` has a label named `…_errout`, setting
`ret |= BLOCK_ERROR | BLOCK_ABORT`, that the `while(1)` extent loop **falls
through into on normal completion** — 100% of arrivals are the fall-through, the
three `goto` sites into it are dead. It is correct : `ret & BLOCK_ERROR` is the
only thing that makes the function return `ctx.errcode` at all, and `ctx.errcode`
is zero on a successful walk. libext2fs does the same thing and calls the label
`extent_done`.

Jumping past the label on success — the obvious fix — was built and measured :
on an image with a corrupted extent index block it turns 0 correctly rejected
files into 2 "recovered" files of 1 966 080 bytes each, **entirely zeros**,
reported as a success. **Issue #36**, **PR #37** (rename and comment only).

Same function, separately : the leaf loop calls the callback 8 more times after
it asked to stop. Known, measured, deliberately not folded into the cosmetic PR.

### Nothing is recovered from an ext4 made by a current mke2fs — and two test cases assert exactly that

`cases/80_listing_and_recovery.sh` carries `nothing is recovered from an ext4
filesystem made with todays defaults` and `a path cannot be resolved on an ext4
filesystem`. They are green today and they are **written to fail loudly** the day
the defects are fixed, with a message saying so :

> this is the outcome to want -- update this test case rather than leave it
> passing

So a red run on those two is the wanted outcome of a fix, not a regression you
introduced. Invert them in the same landing. Three defects are behind it, none
sufficient alone : csum_v3 journal tags are 16 bytes and are read as 8 or 12
(**#15**, **#42**, PR #43), extent trees are opened with inode number `0` so
every checksum below the root node fails (**#38**, PR #39), and the extent walk
is hand-rolled (**#13**, PR #33). **Issue #44** tracks the test update, **PR #45**
carries it.

`tests/lib/images.sh` knows about this too : `populate_and_delete()` skips its
journal precondition check on ext4, because retrying three times for something
already reported as broken would report it twice.

### Below root, every mode is silently cleared

`src/ext4magic.c:712` is `if (getuid()) mode = 0;` — no message, no diagnostic,
exit 0. That is why 115 test cases skip unprivileged, and it is a defect
(**issue #17**), not a property to preserve. A filesystem that could not be
opened also still exits 0 (**issue #16**). Test cases assert on today's
behaviour in both places; changing either will need those updated.

### `src/ext2fsP.h` and `kernel-jbd.h` are stale private copies

`ext2fsP.h` is libext2fs's *private* header, copied in. `struct extent_path`
drifted, so with libext2fs 1.47 the hand-rolled extent handle overflows the heap
(**issue #5**) and aborts on any multi-level extent tree (**issue #13**). PR #33
replaces the lot with the public extent API. Until it lands, anything touching
extents is working against a copy that does not match the library it links
against.

### `journal.c` and `recover.c` compile by include-order luck

`ext2fs.h` guards its own `<sys/types.h>` behind `HAVE_SYS_TYPES_H`, which comes
from the generated `config.h`. Those two reach `ext2fs.h` *before* `config.h`,
and only compile because each happens to include a POSIX header declaring
`dev_t` and `mode_t` first. Reordering the includes in either re-breaks the musl
build silently. **Issue #31**, **PR #32**; **issue #9** is the musl failure,
**PR #10** fixed the other eight files.

### `--disable-foo` turns the feature *on*

The four `AC_ARG_ENABLE` in `configure.ac` never read `$enableval`, so
`--disable-expert-mode` compiles expert mode in. **Issue #1**, **PR #2**. When a
test needs the feature off, omit the flag; do not pass `--disable-`.

The expert options `-Q -c -D -s -n` only exist in a build configured with
`--enable-expert-mode`, and a default build must refuse them — that much *is*
covered by the suite.

### `time_to_string()` hands back one shared buffer, and decides GMT once

It returns `asctime()`'s static buffer, so two calls in one `printf` print the
same string. It also caches the `TZ == "GMT"` decision in a `static` on the first
call, so changing `TZ` afterwards does nothing. Both are asserted by
`tests/unit/10_utility_helpers.c`. The suite pins `LC_ALL=C` and `LANG=C` in
`setup_test_context()` for the same family of reasons.

### `is_unicode()` skips the third byte of a four byte sequence

`src/util.c:674` advances its pointer twice, so a four byte UTF-8 sequence is
validated on bytes 1 and 3 and never on byte 2. **Issue #21**. The suite
deliberately asserts nothing about it — writing down what it returns today would
be recording the defect as correct — and the issue carries the assertion to add
once it is fixed.

### A recovery comes from the *oldest* journal copy, which is what makes the fixtures retry

ext4magic recovers from the oldest inode copy the journal kept. If jbd2 commits
between creating a file and chmod'ing it, the copy recovered from predates the
chmod : the bytes are right and the mode is not. So `build_until_recoverable()`
takes a verifier and retries on a **fresh** image up to three times, and then
**fails** rather than skips. One miss is jbd2 checkpointing early; three
independent images coming up empty is ext4magic no longer recovering anything,
which is the one thing the fixture must not hide.

If you make a recovery test flaky, the fix is to make the fixture wait for the
same thing the assertions check — not to loosen the assertion.

### `-D_FILE_OFFSET_BITS=64` is duplicated on purpose

It is in `src/Makefile.am` and repeated in `tests/unit/build.sh`. It changes the
size of `off_t` and therefore the layout of the structures under test : building
the unit tests without it would be testing a different program. The comment in
`build.sh` says so — keep the two in step.

## Things not to do here

- Do not commit `configure` or `config.h.in` churn. See the first invariant.
- Do not add a linter, a formatter or a CI job as a side effect of another
  change. There is deliberately none.
- Do not reformat old C. Match the file.
- Do not "fix" a test case that is written to fail loudly. Invert it, with the
  behaviour change, in one commit.
- Do not fold an untested behavioural change into a cosmetic pull request. The
  repository's own issues do this consistently and say so when they decline to.
