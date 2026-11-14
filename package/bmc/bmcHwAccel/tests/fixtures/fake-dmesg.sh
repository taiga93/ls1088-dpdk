#!/bin/sh
# Stand-in for dmesg: what cdx logs about the microcode of the network hardware when it is loaded (texts of
# the module's source; the first one was seen on the board).
#   FAKE_MICROCODE=ask       the microcode that accelerates
#   FAKE_MICROCODE=public    the public microcode, which cdx refuses
#   FAKE_MICROCODE=none      cdx never got that far, or the line is no longer in the kernel log
echo '[    1.812345] fsl-fman 1a00000.fman: FMan-Controller code (ver 210.10.1)'
case "${FAKE_MICROCODE:-none}" in
	ask) echo '[   58.484938] cdx: FMAN firmware 210.10.1 - ASK supported' ;;
	public) echo '[   58.484938] cdx: FMAN firmware 106.4.18 lacks ASK support (need package >= 209). Load the ASK microcode in U-Boot.' ;;
esac
