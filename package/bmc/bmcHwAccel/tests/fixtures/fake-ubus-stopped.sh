#!/bin/sh
# Stand-in for ubus while procd does not run the daemon:
#   call service list '{"name":"cmm"}'
echo '{}'
