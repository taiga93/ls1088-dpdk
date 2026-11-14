#!/bin/sh
# Stand-in for ubus while procd runs the daemon (output of procd for a service with one instance, trimmed):
#   call service list '{"name":"cmm"}'
cat <<'JSON'
{
	"cmm": {
		"instances": {
			"cmm": {
				"running": true,
				"pid": 3172,
				"command": [
					"/usr/sbin/cmm-supervise"
				],
				"term_timeout": 5,
				"respawn": {
					"threshold": 3600,
					"timeout": 5,
					"retry": 0
				}
			}
		}
	}
}
JSON
