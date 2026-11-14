#!/bin/sh
# Fake vtysh for tests: simulates FRR not running (vtysh cannot reach the daemon socket).
exit 1
