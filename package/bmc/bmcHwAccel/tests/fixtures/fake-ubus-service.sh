#!/bin/sh
# Stand-in for ubus while procd runs the service named $FAKE_SERVICE, and no other:
#   call service list '{"name":"<service>"}'
for arg in "$@"; do
	case "$arg" in
		*"\"name\":\"${FAKE_SERVICE:-}\""*)
			printf '{\n\t"%s": {\n\t\t"instances": {\n\t\t\t"%s": {\n\t\t\t\t"running": true\n\t\t\t}\n\t\t}\n\t}\n}\n' \
				"$FAKE_SERVICE" "$FAKE_SERVICE"
			exit 0
			;;
	esac
done
printf '{\n}\n'
