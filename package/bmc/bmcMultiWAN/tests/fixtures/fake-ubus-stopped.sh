#!/bin/sh
# Stand-in for `ubus call service list '{"name":"mwan3"}'` once mwan3 is stopped: procd forgot the service.
echo '{'
echo '}'
