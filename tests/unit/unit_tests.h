/***************************************************************************
 *   Unit test framework for ext4magic.                                    *
 *                                                                         *
 *   ext4magic is a recovery tool : most of what it does needs a whole     *
 *   filesystem underneath it, and the shell suite in tests/cases covers   *
 *   that. But its small helpers and its four data structures are plain C  *
 *   with no filesystem behind them, and those are the pieces a shell test *
 *   can only reach through several layers of indirection. They are tested *
 *   here, by linking the real translation units and calling them.         *
 *                                                                         *
 *   A test declares itself :                                              *
 *                                                                         *
 *     UNIT_TEST(parse_ulong_reads_a_plain_decimal_number) {               *
 *       int error = 0;                                                    *
 *       ASSERT_EQ_ULONG(42, parse_ulong("42", "t", "n", &error), "");     *
 *       ASSERT_EQ_INT(0, error, "a well formed number is not an error");  *
 *     }                                                                   *
 *                                                                         *
 *   and the runner picks it up on its own, through the constructor the    *
 *   macro plants. Nothing else to register.                               *
 *                                                                         *
 *   Assertions record their outcome and let the test carry on, exactly    *
 *   like the shell suite's, so a loop over a table of inputs reports      *
 *   every offending row in one run instead of only the first.             *
 *                                                                         *
 *   Each test is run in its OWN PROCESS by tests/run_tests.sh. That is    *
 *   deliberate : the code under test is C dealing with untrusted on-disk  *
 *   structures, and a test that segfaults has to be reported as a failing *
 *   test case rather than take the whole suite down with it.              *
 ***************************************************************************/

#ifndef EXT4MAGIC_UNIT_TESTS_H
#define EXT4MAGIC_UNIT_TESTS_H

#include <stddef.h>

typedef void (*unit_test_function)(void);

/* Called by the constructor the UNIT_TEST macro plants. The runner refuses to
   start if two tests share a name, for the same reason the shell runner does :
   the second definition would silently shadow the first and one of the two
   tests would simply stop existing while the suite stayed green */
void register_unit_test(const char *name, const char *file, unit_test_function function);

/* Assertions. Each records its outcome and returns, so the test carries on */
void unit_assert_equal_long(long expected, long actual, const char *message, const char *file, int line);
void unit_assert_equal_ulong(unsigned long expected, unsigned long actual, const char *message, const char *file, int line);
void unit_assert_equal_string(const char *expected, const char *actual, const char *message, const char *file, int line);
void unit_assert_equal_memory(const void *expected, const void *actual, size_t length, const char *message, const char *file, int line);
void unit_assert_true(int condition, const char *message, const char *file, int line);
void unit_assert_null(const void *pointer, const char *message, const char *file, int line);
void unit_assert_not_null(const void *pointer, const char *message, const char *file, int line);
void unit_assert_string_contains(const char *haystack, const char *needle, const char *message, const char *file, int line);

/* Unconditionally fail, and skip, mirroring fail() and skip_test() in
   tests/lib/assertions.sh */
void unit_fail(const char *message, const char *file, int line);
void unit_skip(const char *reason);

#define ASSERT_EQ_INT(expected, actual, message) \
  unit_assert_equal_long((long) (expected), (long) (actual), (message), __FILE__, __LINE__)
#define ASSERT_EQ_LONG(expected, actual, message) \
  unit_assert_equal_long((long) (expected), (long) (actual), (message), __FILE__, __LINE__)
#define ASSERT_EQ_ULONG(expected, actual, message) \
  unit_assert_equal_ulong((unsigned long) (expected), (unsigned long) (actual), (message), __FILE__, __LINE__)
#define ASSERT_EQ_STR(expected, actual, message) \
  unit_assert_equal_string((expected), (actual), (message), __FILE__, __LINE__)
#define ASSERT_EQ_MEM(expected, actual, length, message) \
  unit_assert_equal_memory((expected), (actual), (length), (message), __FILE__, __LINE__)
#define ASSERT_TRUE(condition, message) \
  unit_assert_true((condition) ? 1 : 0, (message), __FILE__, __LINE__)
#define ASSERT_FALSE(condition, message) \
  unit_assert_true((condition) ? 0 : 1, (message), __FILE__, __LINE__)
#define ASSERT_NULL(pointer, message) \
  unit_assert_null((pointer), (message), __FILE__, __LINE__)
#define ASSERT_NOT_NULL(pointer, message) \
  unit_assert_not_null((pointer), (message), __FILE__, __LINE__)
#define ASSERT_STR_CONTAINS(haystack, needle, message) \
  unit_assert_string_contains((haystack), (needle), (message), __FILE__, __LINE__)
#define FAIL(message) unit_fail((message), __FILE__, __LINE__)
#define SKIP(reason) unit_skip((reason))

/* Declares a test and registers it before main() runs.
   The name is the test's identity : the runner reports it, humanized, exactly
   as it humanizes the shell suite's function names */
#define UNIT_TEST(name)                                                  \
  static void name(void);                                                \
  static void __attribute__((constructor)) register_##name(void) {       \
    register_unit_test(#name, __FILE__, name);                           \
  }                                                                      \
  static void name(void)

#endif
