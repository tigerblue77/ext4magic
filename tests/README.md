# Test suite

Automated tests for ext4magic. The suite builds its own ext2, ext3 and ext4
filesystems from scratch with e2fsprogs, so it needs **no disk of yours, no
fixture checked into the repository and no network** : `bash`, `coreutils`,
`gcc` and `e2fsprogs` are enough.

```bash
./tests/run_tests.sh                 # run everything
./tests/run_tests.sh --list          # list the test cases without running them
./tests/run_tests.sh -f recovery     # only run the test cases whose name matches
./tests/run_tests.sh --tap           # emit TAP version 13 output for a CI parser
./tests/run_tests.sh --junit FILE    # write a JUnit XML report
./tests/run_tests.sh --summary FILE  # append a Markdown report
./tests/run_tests.sh --no-color      # disable colored output
```

It exits `0` when every test case passed, `1` otherwise. Build ext4magic first
(`./configure && make`), or point the suite at another copy with
`EXT4MAGIC_BINARY=/path/to/ext4magic`.

## Run it as root

Two things need it, and both are about ext4magic rather than about the suite :

- a real journal is only written by a **mounted** filesystem, and the journal is
  what ext4magic recovers from, so the test cases that recover something mount a
  loop device to produce one ;
- ext4magic clears its whole operation mode for a caller whose uid is not zero
  (`if (getuid()) mode = 0;` in `ext4magic.c`), so below root even `-S` prints
  nothing at all.

Without root those test cases **skip**, and the run says so on its first line
rather than passing quietly. The CI runs the suite both ways : once as root for
the full set, and once unprivileged to check that a contributor without it still
gets a readable result.

## What is covered

| File | What it checks |
| --- | --- |
| `cases/10_the_test_suite_itself.sh` | The runner and the two reports : the ways this suite could stay green while verifying nothing |
| `cases/20_command_line_options.sh` | Every option, the modes that exclude each other, and what the usage text promises |
| `cases/30_time_window.sh` | The `-a` / `-b` window, its two defaults, and the 1980 floor under it |
| `cases/40_filesystem_handling.sh` | Opening a filesystem and refusing to, every type, block size and inode size, external journals, and the promise that nothing is ever written back |
| `cases/50_superblock_report.sh` | `-S`, field by field, cross-checked against `dumpe2fs` |
| `cases/60_journal_report.sh` | `-J` and `-T`, cross-checked against `dumpe2fs` |
| `cases/70_inode_and_block_dump.sh` | `-I` and `-B`, and the two hexadecimal formats `-x` chooses between |
| `cases/80_listing_and_recovery.sh` | Resolving a path, listing what was deleted, and recovering it — compared **byte for byte** against what went in |
| `cases/90_magic_scan.sh` | `-m` and `-M` : the three passes, where what they find is written, and that they come back on a damaged filesystem |
| `unit/10_utility_helpers.c` | `parse_ulong`, `time_to_string`, `get_inode_mode_type`, `zero_space`, `is_unicode` |
| `unit/20_ring_buffer.c` | The ring of journal inode copies a recovery chooses from |
| `unit/30_directory_list.c` | The directory rebuilt out of old journal blocks, and what its clean up keeps |
| `unit/40_hard_link_stack.c` | The database that turns several names on one inode into links rather than copies |
| `unit/50_extent_database.c` | The ext4 extent cache : what it merges, what it keeps apart, and what it can find again |

## Two kinds of test case, one report

ext4magic is a C program that reads filesystems, so most of it can only be
tested by running it against one. That is the shell suite in `cases/`.

Its small helpers and its four data structures need no filesystem at all, and
reaching them through the whole program would say very little about them. Those
are tested in C, in `unit/`, by linking the real translation units and calling
them.

The runner drives both and reports them together, so one run and one report
cover the whole suite. Each unit test runs in **its own process** : the code
under test parses on-disk structures, and a test that segfaults has to be one red
line rather than a dead suite.

## Reports

Beside the output it prints while it runs, the suite writes two reports for
whoever reads the run afterwards :

| Option | What it produces |
| --- | --- |
| `--junit FILE` | A JUnit XML report. The [`Tests`](../.github/workflows/tests.yml) workflow publishes it, which is what turns a pull request into a test result comment and a check run listing every test case |
| `--summary FILE` | A Markdown report, **appended** to the file, written for `$GITHUB_STEP_SUMMARY` : a table per suite, every test case that ran, and each failure with what it expected, what it obtained and the command to run it again on its own |

Both are built from the same recorded results, so they can never disagree, and
both are written whatever the outcome : a red run is the one whose report matters
most.

## Layout

```
tests/
├── run_tests.sh          entry point : discovers, runs and reports
├── cases/                the shell test cases
├── lib/
│   ├── assertions.sh     assert_equals, assert_contains, assert_files_identical...
│   ├── harness.sh        the environment a test case runs in, and running ext4magic
│   ├── images.sh         builders for the ext2/ext3/ext4 images under test
│   └── reports.sh        the JUnit XML and Markdown reports
└── unit/
    ├── unit_tests.h      the C test framework : UNIT_TEST, ASSERT_*
    ├── unit_tests.c      its registry and the two commands the runner drives it with
    ├── stubs.c           the globals the linked translation units expect
    ├── build.sh          builds the unit test binary out of src/ and unit/
    └── *.c               the unit tests themselves
```

## Adding a shell test case

Add a function named `test_<what it checks>` to the relevant file in `cases/` :
the runner picks it up on its own, in declaration order, and turns its name into
the line it reports. Nothing else to register. Its name has to be unique across
the whole suite, every case file being sourced into the same shell and every unit
test sharing the same namespace : the runner refuses to run rather than let one
definition silently replace another.

```bash
function test_a_deleted_file_comes_back_whole() {
  require_root || return 0
  require_loop_mount || return 0

  local -r IMAGE="$(make_image --type ext3)"
  populate_and_delete "$IMAGE"
  local -r TARGET="$(new_recovery_directory)"

  run_ext4magic -M -d "$TARGET" -a "$DELETION_MARK_TIME" "$IMAGE"

  assert_files_identical "$ORIGINALS_DIRECTORY/documents/notes.txt" \
    "$TARGET/documents/notes.txt" "the file that was deleted"
}
```

Assertions record their outcome and let the test case carry on, so a loop over
three block sizes reports every offending one in one run. Use
`assert_... || return 1` when the rest of the test case cannot run once the
assertion failed.

A test case that records **no** assertion is reported as a failure : it verified
nothing, which is the one failure a passing suite cannot show you.

Describing the filesystem to test against is done through `make_image`
(`--type`, `--size`, `--block-size`, `--inode-size`, `--features`, `--label`,
`--journal-megabytes`), and filling and emptying it through `populate_and_delete`,
which mounts it, writes a known tree, deletes part of it and leaves
`$ORIGINALS_DIRECTORY` and `$DELETION_MARK_TIME` behind. `run_ext4magic` runs the
binary and leaves `$CAPTURED_STDOUT`, `$CAPTURED_STDERR`, `$CAPTURED_OUTPUT` and
`$CAPTURED_EXIT_CODE`. See `lib/images.sh` and `lib/harness.sh` for the rest.

## Adding a unit test

Add a `UNIT_TEST(test_...)` to the relevant file in `unit/`. The macro registers
it before `main()` runs, so there is nothing else to do :

```c
UNIT_TEST(test_parse_ulong_reads_a_plain_decimal_number) {
  int error = 1;

  ASSERT_EQ_ULONG(42UL, parse_ulong("42", "ext4magic", "number", &error), "42 should parse");
  ASSERT_EQ_INT(0, error, "a well formed number is not an error");
}
```

A new `.c` file in `unit/` is picked up on its own and becomes a suite of its
own, named after the file the same way a `cases/` file is. To reach a part of
`src/` that is not linked yet, add it to `SOURCES_UNDER_TEST` in
`unit/build.sh` — and to `unit/stubs.c` whatever globals it expects that
`ext4magic.c` would otherwise own.
