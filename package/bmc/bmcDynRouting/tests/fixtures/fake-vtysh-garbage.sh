#!/bin/sh
# Fake vtysh for tests: exits 0 but prints a non-JSON error line, as vtysh does for an
# unrecognised command against a daemon that answered but doesn't support "... json".
printf '%s\n' '% Unknown command.'
