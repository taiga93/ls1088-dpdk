/*
 * A small test runner: TEST(name) { ... CHECK(cond); ... }. The program
 * runs every test, or the ones named after "--", and prints one line per
 * test. A failed CHECK ends its test.
 */
#ifndef BMCHWACCEL_TESTLIB_H
#define BMCHWACCEL_TESTLIB_H

#include <stdio.h>
#include <string.h>

struct test {
	const char *name;
	void (*fn)(void);
};

extern struct test tests[];
extern unsigned ntests;
extern int test_failed;

void test_add(const char *name, void (*fn)(void));
void test_fail(const char *file, int line, const char *what);
/* Runs the tests named in argv (all of them without names); 0 when all passed. */
int test_main(int argc, char **argv);

#define TEST(name)							\
	static void name(void);						\
	__attribute__((constructor)) static void name##_add(void)	\
	{ test_add(#name, name); }					\
	static void name(void)

#define CHECK(cond)							\
	do {								\
		if (!(cond)) {						\
			test_fail(__FILE__, __LINE__, #cond);		\
			return;						\
		}							\
	} while (0)

/* CHECK for helpers that return int: 0 passed */
#define CHECKR(cond)							\
	do {								\
		if (!(cond)) {						\
			test_fail(__FILE__, __LINE__, #cond);		\
			return 1;					\
		}							\
	} while (0)

#endif
