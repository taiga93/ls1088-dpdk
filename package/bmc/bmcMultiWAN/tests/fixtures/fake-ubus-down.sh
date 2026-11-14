#!/bin/sh
# Stand-in for ubus when ubusd does not answer.
echo 'Failed to connect to ubus' >&2
exit 4
