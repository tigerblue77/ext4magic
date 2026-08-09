/***************************************************************************
 *   The unit test framework's implementation : the registry, the          *
 *   assertions and the two commands tests/run_tests.sh drives it with.    *
 *                                                                         *
 *     unit_tests --list          one "<source file>\t<test name>" per     *
 *                                line, in registration order              *
 *     unit_tests --run <name>    run that one test, print its diagnostics *
 *                                on stdout, and exit 0 (passed), 1        *
 *                                (failed) or 77 (skipped, the autotools   *
 *                                convention). The last line is always     *
 *                                "# assertions <n>", which is how the     *
 *                                runner counts what a test verified       *
 *                                                                         *
 *   A test that records no assertion is reported as a failure rather than *
 *   counted among the green ones : it verified nothing, which is the one  *
 *   failure a passing suite cannot show you. The shell runner applies the *
 *   same rule to its own test cases.                                      *
 ***************************************************************************/

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "unit_tests.h"

#define MAXIMUM_UNIT_TESTS 512

struct registered_unit_test {
  const char *name;
  const char *file;
  unit_test_function function;
};

static struct registered_unit_test registered_tests[MAXIMUM_UNIT_TESTS];
static int registered_test_count = 0;

static int recorded_assertions = 0;
static int recorded_failures = 0;
static int was_skipped = 0;

void register_unit_test(const char *name, const char *file, unit_test_function function) {
  int index;

  if (registered_test_count >= MAXIMUM_UNIT_TESTS) {
    fprintf(stderr, "unit_tests: more than %d tests registered, raise MAXIMUM_UNIT_TESTS\n",
            MAXIMUM_UNIT_TESTS);
    exit(2);
  }

  /* Two tests under one name : the runner would list the name once and run
     whichever definition the linker kept, so the other test would quietly stop
     existing. Refused here rather than discovered later */
  for (index = 0; index < registered_test_count; index++) {
    if (strcmp(registered_tests[index].name, name) == 0) {
      fprintf(stderr, "unit_tests: test name \"%s\" is declared twice (%s and %s)\n",
              name, registered_tests[index].file, file);
      exit(2);
    }
  }

  registered_tests[registered_test_count].name = name;
  registered_tests[registered_test_count].file = file;
  registered_tests[registered_test_count].function = function;
  registered_test_count++;
}

static void record_assertion(void) {
  recorded_assertions++;
}

static void record_failure(const char *message, const char *file, int line) {
  recorded_failures++;
  printf("%s\n", (message && *message) ? message : "assertion failed");
  printf("  at %s:%d\n", file, line);
}

void unit_assert_equal_long(long expected, long actual, const char *message, const char *file, int line) {
  record_assertion();
  if (expected == actual) {
    return;
  }
  record_failure(message, file, line);
  printf("  expected: [%ld]\n", expected);
  printf("  actual:   [%ld]\n", actual);
}

void unit_assert_equal_ulong(unsigned long expected, unsigned long actual, const char *message, const char *file, int line) {
  record_assertion();
  if (expected == actual) {
    return;
  }
  record_failure(message, file, line);
  printf("  expected: [%lu]\n", expected);
  printf("  actual:   [%lu]\n", actual);
}

void unit_assert_equal_string(const char *expected, const char *actual, const char *message, const char *file, int line) {
  record_assertion();
  if (expected == NULL && actual == NULL) {
    return;
  }
  if (expected != NULL && actual != NULL && strcmp(expected, actual) == 0) {
    return;
  }
  record_failure(message, file, line);
  printf("  expected: [%s]\n", expected ? expected : "(null)");
  printf("  actual:   [%s]\n", actual ? actual : "(null)");
}

void unit_assert_equal_memory(const void *expected, const void *actual, size_t length, const char *message, const char *file, int line) {
  size_t index;
  const unsigned char *expected_bytes = (const unsigned char *) expected;
  const unsigned char *actual_bytes = (const unsigned char *) actual;

  record_assertion();
  if (expected != NULL && actual != NULL && memcmp(expected, actual, length) == 0) {
    return;
  }
  record_failure(message, file, line);
  if (expected == NULL || actual == NULL) {
    printf("  one of the two buffers is NULL\n");
    return;
  }
  for (index = 0; index < length; index++) {
    if (expected_bytes[index] != actual_bytes[index]) {
      printf("  first difference at byte %lu : expected 0x%02x, got 0x%02x\n",
             (unsigned long) index, expected_bytes[index], actual_bytes[index]);
      return;
    }
  }
}

void unit_assert_true(int condition, const char *message, const char *file, int line) {
  record_assertion();
  if (condition) {
    return;
  }
  record_failure(message, file, line);
}

void unit_assert_null(const void *pointer, const char *message, const char *file, int line) {
  record_assertion();
  if (pointer == NULL) {
    return;
  }
  record_failure(message, file, line);
  printf("  expected a NULL pointer, got %p\n", pointer);
}

void unit_assert_not_null(const void *pointer, const char *message, const char *file, int line) {
  record_assertion();
  if (pointer != NULL) {
    return;
  }
  record_failure(message, file, line);
  printf("  expected a non-NULL pointer\n");
}

void unit_assert_string_contains(const char *haystack, const char *needle, const char *message, const char *file, int line) {
  record_assertion();
  if (haystack != NULL && needle != NULL && strstr(haystack, needle) != NULL) {
    return;
  }
  record_failure(message, file, line);
  printf("  substring: [%s]\n", needle ? needle : "(null)");
  printf("  text:      [%s]\n", haystack ? haystack : "(null)");
}

void unit_fail(const char *message, const char *file, int line) {
  record_assertion();
  record_failure(message, file, line);
}

void unit_skip(const char *reason) {
  was_skipped = 1;
  printf("%s\n", reason ? reason : "no reason given");
}

static int list_tests(void) {
  int index;

  for (index = 0; index < registered_test_count; index++) {
    printf("%s\t%s\n", registered_tests[index].file, registered_tests[index].name);
  }
  return 0;
}

/* Nothing under test here should take a second, and a unit test that never
   comes back would otherwise be reported as a CI job that timed out, with
   nothing saying which test was running. SIGALRM kills the process, and the
   runner reports the signal against this test's name */
#define SECONDS_A_UNIT_TEST_MAY_TAKE 60

static int run_one_test(const char *name) {
  int index;

  for (index = 0; index < registered_test_count; index++) {
    if (strcmp(registered_tests[index].name, name) != 0) {
      continue;
    }

    alarm(SECONDS_A_UNIT_TEST_MAY_TAKE);
    registered_tests[index].function();
    alarm(0);

    /* A skip states that nothing was verified, so it cannot also hide a
       failure : anything that failed before the skip still counts */
    if (was_skipped && recorded_failures == 0) {
      printf("# assertions %d\n", recorded_assertions);
      return 77;
    }
    if (recorded_assertions == 0 && recorded_failures == 0) {
      printf("the test recorded no assertion, so it verified nothing\n");
      recorded_failures++;
    }
    printf("# assertions %d\n", recorded_assertions);
    return recorded_failures == 0 ? 0 : 1;
  }

  fprintf(stderr, "unit_tests: no test named \"%s\"\n", name);
  return 2;
}

int main(int argc, char **argv) {
  /* Line buffered, so that the diagnostics a crashing test already printed are
     not lost with the buffer when it dies */
  setvbuf(stdout, NULL, _IOLBF, 0);

  if (argc == 2 && strcmp(argv[1], "--list") == 0) {
    return list_tests();
  }
  if (argc == 3 && strcmp(argv[1], "--run") == 0) {
    return run_one_test(argv[2]);
  }
  if (argc == 2 && strcmp(argv[1], "--count") == 0) {
    printf("%d\n", registered_test_count);
    return 0;
  }

  fprintf(stderr, "Usage: %s --list | --count | --run <test name>\n", argv[0]);
  return 2;
}
