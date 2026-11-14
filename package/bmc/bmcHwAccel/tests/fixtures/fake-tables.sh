#!/bin/sh
# Stand-in for iptables and ip6tables, called as `fake-tables.sh iptables|ip6tables <arguments...>`. Only the
# questions are answered: with $FAKE_RULES "installed" every rule and chain asked for is there, otherwise none.
[ "${FAKE_RULES:-missing}" = installed ]
