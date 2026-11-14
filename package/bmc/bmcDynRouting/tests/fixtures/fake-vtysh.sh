#!/bin/sh
# Fake vtysh for tests: echoes canned JSON for the "show ip ospf ... json" commands, the text of
# "show ip rip" / "show ip rip status" (ripd has no JSON output), and the JSON of "show bgp ipv4 unicast
# [summary] json" captured from FRR 10.2.1 (it ends with "} ", trailing space included).
set -eu
shift # drop -c
case "$1" in
	"show ip ospf neighbor json")
		printf '%s' '{"neighbors":{"10.0.0.2":[{"ifaceName":"eth1","state":"Full/DR"}]}}'
		;;
	"show ip ospf route json")
		printf '%s' '{"routes":{"10.0.1.0/24":[{"nexthops":[{"ip":"10.0.0.2"}],"cost":10}]}}'
		;;
	"show ip ospf database json")
		printf '%s' '{"routerId":"10.0.0.1","routerLinkStates":{}}'
		;;
	"show ip ospf interface json")
		printf '%s' '{"interfaces":{"eth1":{"ospfEnabled":true,"passive":false,"state":"Point-To-Point"}}}'
		;;
	"show ip rip")
		cat "$(dirname "$0")/show-ip-rip.txt"
		;;
	"show ip rip status")
		cat "$(dirname "$0")/show-ip-rip-status.txt"
		;;
	"show bgp ipv4 unicast summary json")
		cat "$(dirname "$0")/show-bgp-summary.json"
		;;
	"show bgp ipv4 unicast json")
		cat "$(dirname "$0")/show-bgp.json"
		;;
	*)
		exit 1
		;;
esac
