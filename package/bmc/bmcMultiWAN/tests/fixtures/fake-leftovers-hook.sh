#!/bin/sh
# Stand-in for the probe of what mwan3 leaves in the kernel: state of an mwan3 that procd no longer runs.
echo 'ip rule 2001'
echo 'iptables chain mwan3_hook'
