/*
 * What the engine and its clients share of the control protocol (ctl.c).
 */
#ifndef BMCHWACCEL_CTL_H
#define BMCHWACCEL_CTL_H

#define ENGINE_PROTOCOL 1	/* version of the control protocol */
#define CTL_GREETING "bmchwaccel-engine %d"	/* what the engine says first, with the version */
#define CTL_SOCKET "/var/run/bmchwaccel-engine.sock"	/* where the engine listens by default */
#define CTL_LINE_MAX 512	/* longest request line, with its newline */

#endif
