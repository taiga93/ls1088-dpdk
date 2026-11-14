#include "testlib.h"

struct test tests[256];
unsigned ntests;
int test_failed;

void
test_add(const char *name, void (*fn)(void))
{
	if (ntests < sizeof(tests) / sizeof(tests[0]))
		tests[ntests++] = (struct test){ name, fn };
}

void
test_fail(const char *file, int line, const char *what)
{
	printf("    %s:%d: %s\n", file, line, what);
	test_failed = 1;
}

static int
wanted(const char *name, int argc, char **argv)
{
	int i;

	if (argc == 0)
		return 1;
	for (i = 0; i < argc; i++)
		if (!strcmp(argv[i], name))
			return 1;
	return 0;
}

int
test_main(int argc, char **argv)
{
	unsigned i, passed = 0, failed = 0;

	for (i = 0; i < ntests; i++) {
		if (!wanted(tests[i].name, argc, argv))
			continue;
		test_failed = 0;
		tests[i].fn();
		printf("%s %s\n", test_failed ? "FAIL" : "ok  ", tests[i].name);
		if (test_failed)
			failed++;
		else
			passed++;
	}
	printf("%u passed, %u failed\n", passed, failed);
	return failed || !passed;
}
