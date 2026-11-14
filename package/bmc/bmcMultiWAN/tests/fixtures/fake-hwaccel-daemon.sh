#!/bin/sh
# Stand-in for /usr/lib/bmcHwAccel/daemon-running: the daemon of Tăng tốc phần cứng runs when $FAKE_HWACCEL is
# "running".
[ "${FAKE_HWACCEL:-}" = running ]
