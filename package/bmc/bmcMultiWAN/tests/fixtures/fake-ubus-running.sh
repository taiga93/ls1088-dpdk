#!/bin/sh
# Stand-in for ubus while mwan3 runs (output of a board, trimmed):
#   call service list '{"name":"mwan3"}'    procd runs mwan3
#   call network.interface.<wan> status     netifd's status of <wan>, from $FAKE_IFACE_DIR/<wan>.json; an
#                                           unknown interface fails like ubus ("Not found", exit code 4)
for arg in "$@"; do
	case "$arg" in
		network.interface.*)
			file="${FAKE_IFACE_DIR:-/nonexistent}/${arg#network.interface.}.json"
			if [ -f "$file" ]; then cat "$file"; exit 0; fi
			echo 'Command failed: Not found' >&2
			exit 4
			;;
	esac
done
cat <<'JSON'
{
	"mwan3": {
		"instances": {
			"track_wan": {
				"running": true,
				"pid": 2873,
				"command": [
					"/usr/sbin/mwan3track",
					"wan"
				],
				"term_timeout": 5,
				"respawn": {
					"threshold": 3600,
					"timeout": 5,
					"retry": 5
				}
			},
			"rtmon_ipv4": {
				"running": true,
				"pid": 2921,
				"command": [
					"/usr/sbin/mwan3rtmon",
					"ipv4"
				],
				"term_timeout": 5
			}
		},
		"triggers": [
			[
				"config.change",
				[
					"if",
					[
						"eq",
						"package",
						"mwan3"
					],
					[
						"run_script",
						"/etc/init.d/mwan3",
						"reload"
					]
				]
			]
		]
	}
}
JSON
