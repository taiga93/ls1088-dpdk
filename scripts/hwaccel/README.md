# Hardware acceleration branch (`hw-accel`)

OpenWrt v25.12.5 plus the NXP ASK fast path for the LS1046A-RDB. This
directory holds the build, check and acceptance scripts of the branch.

| File | What it is for |
|---|---|
| `build.sh` | builds the SD image in the `ubuntu20` container; usage in its header |
| `check-image.sh` | checks a built image before it is written to a card |
| `acceptance.sh` | acceptance run against the board over SSH |
| `build.md` | building the image from a fresh clone, step by step (Vietnamese) |
| `bench.md` | what the PCs on the bench need for `acceptance.sh` |
| `tests/` | tests of the scripts above and of the image; `build.sh test` runs them all |

## Building from a fresh clone

`build.md` in this directory has the same steps in Vietnamese and in more
detail: the build machine, each stage, writing the card, and the messages a
build stops with.

Three things a build needs are not in this repository: the web UI, the ASK
FMan microcode and the download cache. With them in place one command
builds the image. These steps describe the build machine the branch was
made on, a Linux container on an arm64 host with the usual OpenWrt build
tools, where builds run as root. A build from a fresh clone, and one on
an x86-64 host, have not been tried.

1. Clone the branch. It needs about 11 GB for a first build.

   ```
   git clone -b ls1046-hw-accel-ask <url of this repository> bmcfirewall_ls1046-hw-accel
   cd bmcfirewall_ls1046-hw-accel
   ```

2. Clone the web UI into the tree, on the branch that has the scripts the
   services of `files/` call (`dynamicRouting_p2`, at "fix(firewall):
   DHCPGuard keeps its ebtables rules in a chain of its own" or later). See
   "The web UI" below.

   ```
   git clone -b dynamicRouting_p2 http://192.168.2.37:9000/bmc_firewall/bmcwebUI.git package/bmc/bmcwebUI
   ```

3. Get `fman-ucode-ask-210.10.1.bin` from a colleague over an internal
   channel and put it, under that name, into the directory git ignores. It
   is proprietary to NXP and is not in any repository; see "The ASK FMan
   microcode" below.

   ```
   mkdir -p package/firmware/layerscape/fman-ucode/local
   cp <where you saved it>/fman-ucode-ask-210.10.1.bin package/firmware/layerscape/fman-ucode/local/
   ```

4. Give the build a download cache. `build.sh` links `./dl` to
   `../../dl-25.12` when there is no `./dl`, and stops when that directory
   does not exist. An empty directory will do; the build fills it.

   ```
   mkdir dl
   ```

5. Build. The stages are toolchain, image and check; the header of
   `build.sh` has the options. With `HWACCEL_RELEASE=1` a missing microcode
   or one with the wrong sha256 stops the build at once. Without it the
   build goes on with the public microcode and ends with a warning, and
   that image forwards on the CPU only.

   ```
   mkdir -p logs
   HWACCEL_RELEASE=1 scripts/hwaccel/build.sh > logs/hwaccel-build.log 2>&1
   ```

   The first build compiles Node.js for the router, which alone takes about
   an hour on the machine above. On an arm64 host the Go compiler of
   `bmcfirewall` needs a Go installation to start from: `/usr/lib/go`, or
   the one named by `GO_BOOTSTRAP_ROOT`.

6. The log ends with `hwaccel-build: all stages done (release build)` and a
   `check-image: PASS` line above it. The image for the SD card is

   ```
   bin/targets/layerscape/armv8_64b/openwrt-layerscape-armv8_64b-fsl_ls1046a-rdb-sdboot-squashfs-sdcard.img.gz
   ```

`scripts/hwaccel/build.sh test` runs the tests afterwards (about an hour).
It needs `qemu-system-aarch64`, `dtc` and `python3`. Without a built 24.10
tree next to this one (`../bmcfirewall_ls1046`, or `FW2410_ROOT`) the
sysupgrade test skips its check against the 24.10 firmware and says so.

## The ASK FMan microcode

Hardware acceleration needs the FMan microcode of the ASK release
(210.10.1). CDX refuses to start on the public 106.x microcode that OpenWrt
downloads.

The file is proprietary to NXP. It is **never committed**. `.gitignore`
excludes it by name and excludes the `local/` directory below;
`tests/ask-ucode-test.sh` fails when these rules are gone or such a file is
tracked. Do not get around them with `git add -f`, and keep the name of the
file. The safest place is a directory outside every git tree (the second one
below).

### Where the file goes

The name and sha256 a build looks for are in
`package/firmware/layerscape/fman-ucode/ask-ucode.sha256`:

```
5f3ed8d32b8659aafd8912d5d9920306350cae7a85884d81859152b9723eff0d  fman-ucode-ask-210.10.1.bin
```

A build looks in two directories, in this order. The first one that has a
file of that name decides; a file there with another sha256 always stops the
build.

1. `package/firmware/layerscape/fman-ucode/local/` in the tree (ignored by
   git).
2. `$ASK_UCODE_DIR`. `build.sh` sets it to `../../ask-ucode` relative to the
   tree, which is `working/ask-ucode` on the build machine; a plain `make`
   defaults to `../ask-ucode`. Set the variable in the environment, to an
   absolute path, to use another directory.

### Development build and release build

| | Development build (default) | Release build |
|---|---|---|
| file found, sha256 right | image has the ASK microcode | image has the ASK microcode |
| file found, sha256 wrong | build fails | build fails |
| no file | image has the public 106.x microcode; warning at the end of the build log; `check-image.sh` passes with a `WARN` line | build fails; the message names the file and the sha256 |

An image with the public microcode still boots and forwards on the CPU; only
hardware acceleration is missing. It must not be released.

To make a release build:

```
docker exec ubuntu20 sh -c 'HWACCEL_RELEASE=1 \
    /home/working/<tree>/scripts/hwaccel/build.sh \
    > /home/working/<tree>/logs/hwaccel-build.log 2>&1'
```

`HWACCEL_RELEASE=1` makes `build.sh` check the file before anything is
compiled and select `CONFIG_FMAN_UCODE_ASK_REQUIRED` in `.config`. With a
hand-made `.config` and a plain `make`, select that option instead
(`make menuconfig`: Firmware, "Release build: fail without the ASK FMan
microcode"); the `layerscape-fman` package then fails the build on its own.
A plain `make` hides the messages of the package: run it with `V=s` to read
why it failed, and note that a development build shows its warning only
there. `build.sh` prints the warning as the last lines of its log.

The image stage of `build.sh` removes the images of the earlier build first,
so a build that fails leaves no image behind.

The package is built again whenever the file appears, disappears or changes,
so an image never keeps the microcode of an earlier build by accident.

`check-image.sh` reads the microcode back from the image and compares its
sha256. In a release build (`HWACCEL_RELEASE=1`, or the option in `.config`)
anything but the ASK microcode is a failure.

### A new ASK microcode

Put the new name and sha256 into `ask-ucode.sha256`. In `check-image.sh`
change `UCODE_SIZE` to the size of the file and the version in its messages;
change the version in this file too.

## The `bmcHwAccel` package and the `bmchwaccel` CLI

Hardware acceleration is a BMC feature, on by default. The package is
`package/bmc/bmcHwAccel`; its only setting is `enabled` in
`/etc/config/bmchwaccel`, which sysupgrade keeps.

```
bmchwaccel get        # {"status":0,"message":"...","enabled":true}
bmchwaccel status     # ...,"state":"on","enabled":true,"accelerated":12,"on_cpu":[]
bmchwaccel disable    # saves enabled 0, then does what apply does
bmchwaccel enable     # saves enabled 1, then does what apply does
bmchwaccel apply      # loads the modules and starts the daemon, or stops the daemon
bmchwaccel --dry-run apply   # prints the plan and changes nothing
```

Every command prints one JSON object; `status` is -1 and the exit code 1 on
an error. `state` says what the router is doing now: `on` while the daemon
runs and answers; `off` when it does not and the feature is disabled;
`unavailable` when it does not although the feature is enabled, with a
`reason` (below). `accelerated` is the number of connections the hardware
forwards. `on_cpu` lists what other features keep on the CPU ("Traffic kept on
the CPU" below).

The service `/etc/init.d/bmcHwAccel` (S54) runs `bmchwaccel apply` at boot.
With `enabled` 1 it loads `cdx`, `auto_bridge` and `fci`, in that order, and
starts `cmm` through `/etc/init.d/cmm`. With `enabled` 0 it loads nothing.
For that:

- the three ASK kernel packages no longer load their module at boot (no
  `AUTOLOAD` in `package/ask/ask-modules/Makefile`; this is an edit inside
  the ASK transplant, to be kept when ASK is updated);
- the init script of `cmm` stays in the image but is disabled at first boot
  (`/etc/uci-defaults/99-bmcHwAccel`).

### Unavailable: enabled, but the hardware does not forward

The router then forwards everything on the CPU, as with the feature disabled.
`bmchwaccel status` says why:

| `reason` | meaning | what to do |
|---|---|---|
| `microcode` | `cdx` refused the FMan microcode: the card carries the public 106.x one | write the whole SD card from an image with the ASK microcode |
| `module` | `cdx`, `auto_bridge` or `fci` did not load, for another reason | `dmesg`; `bmchwaccel apply` tries again |
| `daemon` | the modules are loaded, `cmm` does not run or does not answer | `bmchwaccel apply` starts it again |
| `boot_skipped` | the module load did not return in two boots in a row, so this boot left the modules alone | `bmchwaccel enable` tries again, at once |

```
{"status":0,"message":"Tăng tốc phần cứng is unavailable: its service is not running","state":"unavailable","reason":"daemon","enabled":true,"accelerated":0,"on_cpu":[]}
```

`apply` and `enable` that end like this answer with status -1 and the same
`reason`. Each change to unavailable leaves one syslog line with the tag
`bmcHwAccel` that names the reason (`Tăng tốc phần cứng unavailable: ...`);
asking again while nothing changed logs nothing. `status` itself never logs:
a daemon that stops answering without dying shows in `status` only. The state
logged last is in `/var/run/bmcHwAccel/state`; `microcode-refused` next to it
is how `status` still knows about the microcode once the kernel log has lost
the line of `cdx`.

**A boot that the module load breaks.** Before the first `modprobe`,
`bmchwaccel` writes `/etc/bmcHwAccel/loading` (the number of loads in a row
that did not return, synced to the card) and removes it when the last
`modprobe` has returned, whether the modules loaded or not. A load that
crashes or hangs the router leaves the file behind. With 2 in it, `apply`,
and so the boot, does not touch the modules: the router comes up and forwards
on the CPU, without anyone at the serial console. `bmchwaccel enable` removes
the file and loads the modules at once; if that takes the router down again,
the next boot tries once more and the one after it skips. `disable` keeps the
file. A sysupgrade drops it (it is not a configuration file), so a new
firmware is tried again.

**A daemon that dies.** procd runs `cmm` under
`/usr/lib/bmcHwAccel/supervise` and no longer respawns it itself. When `cmm`
dies by itself, the supervisor

- takes every connection and bridged flow out of the hardware with `cmm -R`
  (`package/ask/cmm/patches/110-empty-the-forward-engine-without-a-daemon.patch`),
  so that open connections continue on the CPU instead of staying in a
  hardware nobody maintains;
- logs `unavailable` for the reason `daemon`;
- starts `cmm` again after 5 s, and logs `turned on` if it answers within
  10 s.

After 5 deaths in a row, each within 5 minutes of its start, it gives up:
the service is no longer running, `status` says `unavailable` with `daemon`,
and `bmchwaccel apply` or `enable` starts over. Before, procd respawned `cmm`
without end; a `cmm` that keeps dying now leaves a router that forwards on
the CPU and says so, instead of one that switches between the two every few
seconds. Two things changed with it: a `cmm` image without `bmcHwAccel` gets
no restart at all, and the CEETM QoS re-apply of `cmm-supervise` (`cmmqos`,
not in this image) runs once per start of the service, no longer after each
restart of `cmm`.

**The daemon starting twice at boot.** The PoC saw `cmm` start twice at boot,
5 s apart, without a line in the log. The cause is not known, and nothing
here fixes one; whether it still happens since the modules are loaded by the
service has not been looked at on the board. What is new is that it shows:
`/var/run/bmcHwAccel/daemon-starts` holds how often the supervisor started
`cmm` since the service was started, the `boot` item of `acceptance.sh`
fails when that is not 1, and a death leaves the `unavailable` line in
syslog. A second start made by stopping and starting the service does not
show in the counter.

Tested without a board: the reasons, the mark and the supervisor with
stand-ins (`tests/run.sh`), and in QEMU the mark over a real boot and the
supervisor under the real procd with a `cmm` that dies at once (it has no
`fci` there). Not run anywhere yet: `cmm -R` against the hardware, and a
`cmm` that dies with connections in it. `bench.md` has the steps.

### Switching on a running router

Run on the board on 2026-10-05 (ticket 08, `toggle` of `acceptance.sh`,
both links at 1 Gbps, PC2 on Ubuntu and on macOS): while disabled the open
TCP sessions go on through the CPU at 500–670 Mbps on average, a new
connection works, and after enabling they are back in the hardware at about
930 Mbps. With a Windows 10 PC2 the sessions stood still for up to 20 s
instead; a capture on PC1 showed bursts of loss that hit every connection at
once, also with acceleration on and nothing switched, followed by macOS's
slow recovery from them. They did not occur with the other two PC2s, so they
came from the Windows PC2 (its card, driver or cable), not from the board.

`bmchwaccel disable` and `bmchwaccel enable` take effect at once, without a
reboot, and each leaves one syslog line with the tag `bmcHwAccel`
(`Tăng tốc phần cứng turned off`, `... turned on`). The line is also written
when the boot turns acceleration on.

- Disabling stops the daemon and waits until it is gone. The modules stay
  loaded. Before it goes, the daemon takes every connection and every bridged
  flow out of the hardware, so open connections continue on the CPU.
- Enabling starts the daemon, which hands the connections that are already
  open to the hardware again.

### Traffic kept on the CPU

A connection the hardware forwards no longer passes qdisc, IFB or the rules
of the firewall. A BMC feature that needs those says which traffic has to
stay on the CPU; the rest is accelerated as before (ADR-0011). `bmcqos` is
the first: while it is on, every connection through the WAN it shapes stays
on the CPU.

```
bmchwaccel keep bmcqos wan eth0   # what the init script of bmcqos runs when it starts
bmchwaccel release bmcqos         # and when bmcqos is stopped or turned off
bmchwaccel status                 # ...,"on_cpu":[{"scope":"wan","device":"eth0","reason":"bmcqos"}]
```

`keep`, `release` and `refresh` are for the features of the firmware, not
for the operator. A reason has one registration; registering again replaces
it, so a feature that moves to another WAN only registers the new one. The
list is not saved: features register again when they start.

How it works:

- A kept connection carries bit `0x10000` in its conntrack mark. The bit is
  outside the marks of mwan3 (`0x3F00`) and of bmcqos (`0xff`); no other
  package of the firmware sets a mark. It is never copied into the mark of a
  packet, so no `ip rule` and no route lookup of the daemon sees it.
- The chain `BMCHWACCEL_KEEP` in mangle `FORWARD` (IPv4 and IPv6) sets the bit
  on every packet that enters or leaves a kept WAN, so a connection has it
  from its first packet.
- The rules cover the registered device and every device stacked on it: its
  VLANs and the PPPoE sessions over it or over one of those. bmcqos registers
  the device that has its qdisc (`eth0`), while what the router forwards
  through a PPPoE wan enters and leaves `pppoe-wan`. Such a device comes and
  goes: `/etc/hotplug.d/iface/20-bmcHwAccel` runs `bmchwaccel refresh` when an
  interface comes up, and a changed set of devices is handled as a change of
  what is kept.
- `cmm` refuses a connection with the bit: `/usr/lib/bmcHwAccel/fastforward`
  holds the rule (`option mark 65536 mask 65536`; the reader of `cmm` takes
  decimal numbers only), and `cmm-supervise` joins it to
  `/etc/config/fastforward` at each start. The joined file is
  `/var/run/bmcHwAccel/fastforward`.
- `cmm` looks at the mark only when it first hands a connection over. After a
  change of what is kept, `bmchwaccel` therefore stops the daemon (which
  empties the hardware), gives every open connection the bit with
  `conntrack -U`, and starts the daemon again. Connections that were open at
  that moment continue on the CPU until they end, also those that do not go
  through the WAN; new ones are sorted by the rules. `release` of the last
  registration clears the bit everywhere and restarts the daemon, which then
  accelerates what is open.
- A firewall restart takes the chain out. The firewall include of the
  package runs `bmchwaccel refresh`, which puts it back and, because
  connections may have been accelerated without the bit meanwhile, does the
  same stop, mark and start. A reload leaves the chain alone.
- The daemon is never started without the chain: `apply` puts it back first,
  and when the rules cannot be installed the daemon stays stopped and the
  router forwards on the CPU. A feature is never left without effect.

Each change leaves a syslog line `bmcHwAccel: Tăng tốc phần cứng keeps on
the CPU: wan eth0 (bmcqos)`.

Consequences: a WAN with `bmcqos` forwards at the speed of the CPU, also on a
10G port; and the limit on traffic through the CPU (next section) applies to
it.

Not covered:

- a connection that was accelerated through another WAN and is then moved
  to the kept one by a route change: the daemon follows the route and does
  not look at the mark again (ticket 17). A Chuyển WAN does not do this:
  the connection is removed and starts anew, with the mark ("Multi-WAN
  next to hardware acceleration");
- `/etc/init.d/firewall stop` or a flush by hand: the chain is gone and
  nothing runs `refresh` until the firewall starts again;
- a `keep` that fails half-way (the daemon does not stop): the feature that
  asked logs the failure, and the next `keep` or `refresh` does the whole
  change again.

### Traffic between two br-lan ports

Traffic that the board bridges, from one `br-lan` port to another, is
accelerated like what the board routes: connection by connection, from what
conntrack knows (the user's decision of 2026-10-10, tickets 19 and 25). On the
board, TCP between two 1G ports of `br-lan` runs at 915 to 921 Mbps in the
hardware and at 390 to 460 Mbps when kept on the CPU.

How a bridged connection gets there: with `bridge-nf-call-iptables` 1, which
the rules of macfilter and client_control need, a connection between two
`br-lan` ports has a conntrack entry, and `cmm` hands it over as it hands
over a routed one.

The other way into the hardware stays closed. `auto_bridge` offers every
bridged flow to `cmm`; with the module's default
(`net.abm.abm_l3_filtering` 0) such a flow is a pair of MAC addresses and an
ethertype, not a connection, and the module does not time out a flow the
hardware has. Nothing conntrack does would take such a flow out again, so
`cmm -B`
(`package/ask/cmm/patches/120-keep-bridged-flows-with-the-bridge.patch`)
answers every flow the module offers with "denied". `auto_bridge` cannot be
left out (`cdx` has no manual bridge mode, and `cmm` exits without the
module). `cmm-supervise` starts the daemon with `-B`; `check-image.sh` fails
on an image that does not. `option bridge '1'` in `config global 'global'` of
`/etc/config/bmchwaccel` makes `cmm-supervise` leave `-B` out; no command sets
it, the image does not have it, and the bridge items of `acceptance.sh` fail
on a board that runs without `-B`.

### The neighbours of machines that talk through a bridge

`cmm` hands a connection to the hardware once the kernel has a neighbour
entry for each end. The kernel resolves the ends of what the router routes;
for a connection between two `br-lan` ports it sends nothing and resolves
nothing. On the board, after a boot, TCP between two ports ran on the CPU at
390 to 590 Mbps although `bmchwaccel status` counted the connection, until
the router happened to talk to both machines. A machine that never talks to
the router (fixed address, another gateway and DNS server) would stay there.

`bmchwaccel sweep` closes that gap (`/usr/lib/bmcHwAccel/neighbours.sh`). Two
rules in `mangle FORWARD` (`-m physdev --physdev-is-bridged`, new connections
only) note both ends of every bridged connection in the ipsets
`bmchwaccel_bridged` and `bmchwaccel_bridged6`, for five minutes. At each
sweep, for a noted address that has no neighbour entry and is on a link of
the router, the kernel is told to resolve it: `ip neigh replace <address> dev
<device> use`. The kernel sends the ARP request or neighbour solicitation
itself; nothing is pinged, and the MAC address is the one the machine answers
with. `cmm` sees the new entry and hands the waiting connections over,
running ones included, and keeps the entry alive while they last.

Measured on the board (ticket 25): with the entry of PC2 deleted, a TCP run
between two ports made 323 to 394 Mbps on the CPU, and 940 Mbps from the
sweep of the next minute on, with no packet on the CPU. cron runs the sweep,
so a first connection can spend up to a minute on the CPU.

### Machines and destinations that a feature blocks on every packet

Both features drop packets by their source MAC address, client_control only
at set hours, and check every packet. A connection in the hardware no longer
passes their chains: on the board, a rule set against a running download
stopped nothing, between two `br-lan` ports and from `br-lan` to wan alike.
A connection opened after the rule is no trouble: its first packet is always
on the CPU.

`bmchwaccel sweep` (`/usr/lib/bmcHwAccel/evict.sh`) closes that gap. `cmm`
hands a connection to the hardware from what conntrack knows and takes it out
when conntrack drops it, so the conntrack entries of a blocked machine are
deleted; its next packet is on the CPU, meets the rule, and opens nothing.
Stopping the daemon would not do: started again, it hands the same entries
back.

- Who is blocked now is said by the features: each program in
  `/usr/share/bmcHwAccel/blocked.d` prints `block <MAC>` (every packet of that
  machine is dropped: all its connections go), or `allowlist` and
  `allow <MAC>` lines (macfilter in whitelist mode: every other machine loses
  the connections it opened). The two programs there call
  `macfilter.sh blocked` and `client_control.sh blocked` of the web UI
  backend.
- Two more features check every packet, by address instead of by MAC address,
  and have a program there that reads their rules as `iptables -S` prints
  them:
  - The blocked services of bmcfirewall (chains `BMC_SVC4`, `BMC_SVC6`) drop
    what goes to a member of the ipset of a service, for one machine or for
    all, at all hours or by schedule. `blocked_services` prints
    `to <set> <MAC>` or `to <set> any` for the rules in force at this hour,
    and `own <MAC>` for a machine that the rules for everybody pass by.
    `sweep` then lists conntrack once and deletes each pair of such a machine
    and a member that have a TCP or UDP connection. This also covers an
    address that DNS put in the set after the connection was opened.
  - bmcfido (chain `BMC_FIDO`) lets a machine of the LAN send while its
    address is in the ipset `authorized_table`, where it stays four hours.
    `bmcfido` prints `only <LAN network> authorized_table`, and `also
    <address>` for the servers the chain names. `sweep` keeps what the set
    held at the last sweep in `/var/run/bmcHwAccel` and takes all connections
    of a machine once, when it has left the set; at the first sweep after
    bmcfido was turned on, of every known machine that is not in it.
  Nothing calls `sweep` for these two when their rules change: cron does,
  within the minute.
- conntrack knows addresses, not MAC addresses. A rule in `mangle FORWARD`
  notes the pair of every machine that opens a connection through the router
  in the ipset `bmchwaccel_hosts` (kept for a week); the neighbour table adds
  the machines the router itself talks to, IPv6 included. `sweep` puts the set
  and the rule back when they are missing, and the firewall runs it after each
  start.
- Who runs it: `macfilter.sh` and `client_control.sh` after they applied
  their rules, and cron every minute. The latter is what makes a rule of
  client_control take hold when its hour begins, in the first seconds of that
  minute.
- Nothing is deleted while the daemon does not run. A line in syslog tells
  how many connections were taken out.

Measured on the board (ticket 25): a macfilter rule for PC1, set by the web UI
script while PC1 sent 840 Mbps of TCP and 100 Mbit/s of UDP to wan, left 2
packets out of wan in the next 5 s; a client_control rule that started at
14:08 left none from 14:08:00 on. `acceptance.sh bridge-block` (two `br-lan`
ports) and `block` (to wan) are the items for it: each sets macfilter,
client_control, a blocked service and bmcfido against a running flow, one
after the other. `bridge-neigh` is the item for the neighbours.

The connections of a blocked machine to the router itself (ssh, the web UI)
are deleted as well, every minute: macfilter and client_control do not stop
those (they are in `FORWARD`), and conntrack cannot be told to leave them.
The kernel picks such a connection up again with its next packet
(`nf_conntrack_tcp_loose`). Measured on the board with PC1 on the blacklist
of macfilter for 150 s and three sweeps that deleted 59, 105 and 108 entries:
259 of 259 web UI requests answered, 30 of 30 requests over one keep-alive
connection that was never reopened, and an ssh session that stayed up.

Accepted (ticket 25): when a client_control rule is set whose hours have not
begun, a TCP run of the machine it names stands still for about 2.5 s.

Not covered, and open:

- the blocked services and bmcfido are not set through their pages in the
  items, and IPv6 (`BMC_SVC6`, neighbours) was not measured on the board;
- a machine with a fixed address that opened its last connection through the
  router more than a week ago, and that the router never talks to itself, is
  not in the table;
- any other feature that drops packets of established connections by a rule
  that can start to match later has the same gap and needs a program in
  `blocked.d` (or `keep`, ADR-0011).

### The limit on traffic through the CPU

While `cdx` is loaded, a packet that the hardware does not forward itself
reaches the CPU through a policer in the hardware ("exception rate"): what
is over the rate is dropped. `cdx` starts it at 195312 with a burst of 64
(`dpa_app`); `cmm -c 'query qmexptrate eth'` shows the rate and the packets
dropped so far. It applies, with acceleration on, to everything that stays on
the CPU.

It is not why the sessions stand still after a runtime disable: after three
`toggle` runs it had dropped no packet (green 605059, red 0). Raising it to
5000000 for the disabled time made the standstill complete, so that change
was taken back. `bmchwaccel` leaves it as `cdx` sets it.

The daemon of ASK mono-1.0.7 does not do the first by itself: stopped, it
left everything in the hardware, where nothing removed it any more.
`package/ask/cmm/patches/100-empty-the-forward-engine-on-stop.patch` changes
that, and two things that go with it:

- bridged flows are refused while the daemon is switching off (ASK only
  refused routed connections);
- `nf_conntrack_tcp_be_liberal` stays 1 after the daemon has gone. The kernel
  last saw a connection's TCP sequence numbers before it was accelerated;
  with the strict check, its packets are invalid when they come back to the
  CPU and the connection breaks. The setting is back to the default after a
  reboot with acceleration disabled.

The patch is a BMC change to the ASK sources: when ASK is updated it has to
apply again, or the build stops.

Known limits at this point:

- After `disable` on a running router, the conntrack entries of the
  connections that were accelerated at that moment keep the `[PERMANENT]`
  mark (`/proc/net/nf_conntrack`). Such an entry does not expire while it is
  a UDP flow or an established TCP connection, also when the connection is
  dead, until acceleration is enabled again or the router reboots. The
  daemon does not clear the mark on purpose: the kernel has not refreshed
  the timeout of an entry while the hardware carried the connection, so an
  entry without the mark could expire at once and take a live connection
  with it. Their number is at most the number of accelerated connections at
  the moment of disabling; the `toggle` item prints it.
- With the daemon stopped nothing can ask the hardware what it still holds.
  That the hardware was emptied is seen from the traffic: its packets reach
  the CPU (`toggle`).
- A stop that takes the daemon longer than 5 s: procd then kills the
  supervisor, not the daemon, which finishes emptying the hardware on its
  own. `bmchwaccel disable` reports `off` as soon as procd says the service
  is gone.
- A daemon that runs but does not answer is reported as `unavailable` with
  `daemon`, but `apply` finds nothing to do and nothing restarts it:
  `/etc/init.d/cmm restart` does.
- After the daemon died, the conntrack entries of the connections it had
  accelerated keep the `[PERMANENT]` mark, as after a runtime disable
  (above), until a daemon runs again or the router reboots.
- Before the service has run in a boot (S54), `status` already says
  `unavailable` with `module`.
- The modules are loaded at S54, with the network up; before, the boot
  loaded them at S10.

Tests of the CLI, with stand-ins for the daemon and for procd, need no board:

```
sh package/bmc/bmcHwAccel/tests/run.sh                 # macOS or Linux
docker exec ubuntu20 sh -c 'cd /home/working/<tree> &&
    ROOTFS=$(ls -d build_dir/target-*/root-layerscape) sh package/bmc/bmcHwAccel/tests/run.sh'
```

The second form runs the CLI with the busybox of the built root filesystem,
and there also executes the plans for real: with the image's own `uci`, and
with stand-ins that take the calls to `modprobe` and to the daemon's init
script. `build.sh test` runs both.

## Boot time: the firmware of the 10G copper PHY

The AQR113C on the 10G copper port has no flash. The kernel uploads its
firmware (`AQR113C.cld`, built into the kernel) over MDIO in the probe of
the PHY: one 32-bit word per three bus writes, about 276000 writes for the
368 KB the PHY takes. The probe runs while the kernel starts its built-in
drivers, so FMan and the network ports are only probed once it is done. At
the MDC frequency U-Boot leaves on that bus this was 27 of the first 33
seconds of the boot (kernel log of the board: `loading firmware` at second
6.3, FMan at second 33.5). The frequency was not read on the board: the 27
seconds fit 1.35 MHz, which is the reset divider on a 700 MHz FMan clock.

The device tree now gives the bus (`mdio@fd000`, the AQR113C is its only
device) `clock-frequency = <2500000>`, the rate every IEEE 802.3 PHY has to
take. By the same arithmetic the upload should take about 14 seconds; this
has not run on a board yet. Two kernel patches go with it:

- `112`: the PHY driver logs `firmware loaded in N ms`.
- `113`: an MDC frequency that cannot be set (no input clock, out of range)
  leaves the bus at the bootloader's frequency with a warning, where the
  mainline driver fails the probe and the port loses its PHY; a clock that is
  not registered yet still defers the probe. The divider is
  rounded so that MDC never exceeds the requested frequency, and the log
  names the frequency that was set and the one before.

What is left, and why it stays:

- The remaining 14 seconds are the upload itself at 2.5 MHz. A faster MDC is
  possible on the controller, but nothing here states what the AQR113C and
  the board's MDIO lines take above the standard rate; a wrong value costs
  the 10G copper port.
- The kernel uploads nothing to a PHY that still has its firmware. Whether
  that is so after a `reboot` of this board has not been looked at.
- `acceptance.sh boot-time` measures it on a board (bench.md).

## The packages of the 24.10 firmware

The image carries the web UI and the firewall features of the 24.10
firmware: `bmcfirewall` (the DNS filter), `bmcfido`, `bmcwebUI`, `easycwmp`
with `libmicroxml`, and the `files/` directory (the services and
configuration of macfilter, client_control, NAT 1:1, ddos_protect, dhcpguard
and acl_control, the certificates of the web UI, the default network and
DHCP configuration). They were taken from branch `multi-wan`; `bmcHA` is
not carried. `package/bmc` has to build on both bases, so a change made
there for this base is tried on the 24.10 tree as well.

What differs from the 24.10 tree:

| | 24.10 tree | this branch |
|---|---|---|
| source of `bmcfirewall`, `easycwmp`, tarball of `libmicroxml` | tracked under `dl/` | next to each Makefile (`src/`, `src/`, `dist/`); `dl/` is a download cache outside git here. The three Makefiles take either place. |
| Node.js on the router | `node` of the packages feed (20.18.3) | the same package, copied to `package/lang/node`: the feed of v25.12.5 builds Node.js for the build host only. `build.sh` removes the feed's `node` from the build. |
| Go compiler for `bmcfirewall` | 1.23 | 1.26, from the feed. On an arm64 build host it needs a Go installation to start from (`GO_BOOTSTRAP_ROOT` in `build.sh`). |
| package manager | opkg (`.ipk`) | apk (`.apk`). A package version must be numbers and dots, so `libmicroxml` is `2012.06.11-r1` on both bases. The "Packages" page of the web UI calls `opkg` and does not work on this base. |
| `files/etc/config/network` | `br-lan` lists `eth1` to `eth7` | `eth1` to `eth5`; the LS1046A-RDB has no `eth6`, `eth7`. On the LS1088A-RDB the first boot adds them (`20_ls1088a-rdb-lan-ports` under `target/linux/layerscape/base-files`) |
| `files/etc/init.d/phy_init` | present | present: it sets up the DPAA2 ports of the LS1088A-RDB, one flow steering entry each (`scripts/ls1088`), and does nothing on the LS1046A-RDB |

A card written from this branch comes up with `br-lan` on **192.168.5.1**,
as the 24.10 firmware does, and hands out its own address as the DNS server:
the DNS filter listens on port 53 and dnsmasq on port 54. Change the address
on the LAN page of the web UI, not with `uci` alone: the DHCP options and
the DNS filter carry the address too.

Not in the image yet: bmcqos and strongSwan (IPsec). The web UI has its
pages for them all the same; what those pages do without the packages has
not been looked at. DynRouting and Multi-WAN have a section of their own
below. The captive portal and the
proxy have a section of their own below.

Also taken over from the 24.10 tree, outside `package/bmc` and `files/`:

- `uhttpd` with the BMC patch for its redirect mode (`redirect_mode`,
  `redirect_host`, `redirect_https_port` in `/etc/config/uhttpd`), the page
  on port 80 that sends a browser on to the web UI, and the pages and
  scripts of the captive portal. On the 24.10 tree this is
  `package/community/uhttpd`; here the changes are made to
  `package/network/services/uhttpd` in place.
- Bridge firewalling on by default (`sysctl-br-netfilter.conf`).
- The system defaults of `config_generate`: time zone `Asia/Ho_Chi_Minh`,
  login on the serial console, `time.cloudflare.com` as the first NTP
  server.

Not taken over, on purpose: the root password of the 24.10 firmware
(`/etc/shadow`; the acceptance scripts log in as root without one).

The files of macfilter, client_control, NAT 1:1 and ddos_protect came from
the 24.10 firmware with defects (ticket 22): none of the four services ran
at boot, and set through the scripts of the web UI, macfilter,
client_control and ddos_protect on `br-lan` had no effect on the traffic.
Ticket 22 fixed them in `files/etc/init.d` and in the scripts of bmcwebUI,
for both firmware lines: the four services run at boot and put back what
was saved, and the chains that stop traffic (`FW_DOS_POLICY`, `MAC_FILTER`,
`CLIENTCTL`) are put in front of the rules of fw3, with the accepting chain
of NAT 1:1 behind them. A firewall restart removes every chain, so fw3 has
an include (`/etc/firewall.bmc-features`, added to `/etc/config/firewall`
by `uci-defaults/99-z-bmc-firewall-features`) that starts the services
which have rules to keep. `acceptance.sh features` and `tests/qemu-test.sh`
check all of this; the web UI has to be at a commit that has the fix.

With syslog-ng in the image the log is in two places: `logread` shows
`/var/log/messages`, which starts when syslog-ng does, and
`/usr/libexec/logread-ubox` shows what logd has (the kernel, procd, and
everything before syslog-ng started). The acceptance scripts read both.

### The web UI

`bmcwebUI` has a repository of its own and is not part of this one
(`package/bmc/.gitignore`). A build takes what is checked out in
`package/bmc/bmcwebUI` and prints its commit; without that directory
`build.sh` stops. To set it up:

```
git clone http://192.168.2.37:9000/bmc_firewall/bmcwebUI.git package/bmc/bmcwebUI
```

The build writes `server.bundle.js` and the `.gz` files of the pages into
that checkout, as on the 24.10 tree.

### Checking them

- `check-image.sh` looks for the programs, services and configuration in the
  root filesystem.
- `tests/bmc-packages-test.sh` runs them from the built root filesystem:
  Node.js reads the web UI and the FIDO server, the DNS filter says its
  version, the services are enabled, the kernel modules of the matches the
  feature scripts use are there.
- `tests/qemu-test.sh` boots the image and runs the three items below
  against it.
- `acceptance.sh webui`, `features` and `features-in` run against the board
  (bench.md, "Web UI và các tính năng firewall"). `features` and
  `features-in` also run against a board on the 24.10 firmware, to compare
  the two.

## IPsec

The image has strongSwan 6.0.3 for the VPN page of the web UI, which writes
`/etc/ipsec.conf` and `/etc/ipsec.secrets` and uses the `ipsec` command (an
IKEv2 tunnel with a shared key, AES-256 with SHA-256, ESP in UDP). The
packages are those of the 24.10 profile, selected one by one in
`config_LS1046ARDB`, without three:

- `strongswan-full`, the package that selects them on 24.10, needs
  `CONFIG_DEVEL` on this base;
- `strongswan-swanctl`: its service starts a second `charon` next to the one
  of the `ipsec` service, and the two cannot run together;
- `strongswan-mod-af-alg`: at every start it asks the kernel for each
  algorithm it knows, and each one the kernel does not have costs a
  `modprobe`. In the QEMU test that took longer than the starter waits; it
  then killed `charon` and started it again without end, and under that load
  a firewall reload came out without the rules of its zones. The `openssl`
  plugin has what IKE needs.

strongSwan negotiates the keys; the kernel has them. ASK was built with its
IPsec part (kernel patch `040-ask-xfrm-ipsec-offload`, `cdx` with
`DPA_IPSEC_OFFLOAD`, the key tracking of `cmm`): next to a running daemon
the keys are handed to the hardware, which then encrypts and decrypts what
goes through a tunnel. **That has not run on the board.** `tests/qemu-test.sh`
brings a tunnel up between the board and a second strongSwan through the
script of the VPN page and sends traffic through it, with the kernel doing
the IPsec, as `cdx` cannot load there.

## bmcqos

`package/bmc/bmcqos` is the package of the 24.10 firmware (classification
with fw3, CAKE on the WAN device and on an IFB for what comes in), with its
kernel modules and `tc` in the image. Differences from 24.10:

- its init script registers the WAN it shapes with `bmchwaccel` ("Traffic
  kept on the CPU" above). A restart or a reload keeps the registration
  through its stop, so the daemon of hardware acceleration is not restarted
  twice and the WAN is never accelerated in between;
- the default configuration is `enabled '0'` and `WAN 'eth0'`. The 24.10
  package ships `enabled '1'` on `eth1` at 90/45 Mbit/s; on this base `eth1`
  is a port of `br-lan`, so that default would have limited that LAN port;
- `usr/lib/tc/m_xt.so`, an x86-64 binary the package never installed, is not
  carried.

`acceptance.sh` has the items `qos`, `qos-back` and `qos-vlan-vlan`, and
`keep-mark` for the mechanism alone (`bench.md`).

## ddos_protect and the dashboard (ticket 18)

### What ddos_protect limits

`ddos_protect` (`files/etc/init.d/ddos_protect`, driven by the web UI through
`.../firewall/ddos_protect.sh`) installs a chain `FW_DOS_POLICY` and, since
ticket `22`, jumps to it first thing in **`INPUT`** and in **`FORWARD`**: it
limits what comes in on its configured interface (`br-lan` as the firmware
ships it), both what is sent **to the router itself** and what the router
**forwards**. The two share one set of limits:

| what | limit |
|---|---|
| new SSH connections (TCP SYN to port 22) of one source | the 5th within 60 s is dropped |
| TCP SYN | 20 a second, burst 40 |
| UDP packets of a flow that has had no reply yet (conntrack state NEW) | 100 a second, burst 150 |
| ICMP echo requests | 1 a second, burst 5 |

(As carried from the 24.10 firmware the chain was appended to `INPUT` only,
behind the rules of fw3 that had accepted the packet already, the service did
not start at boot, and the SSH rule counted every packet of a session rather
than its first. Forwarding was added by the decision of 2026-10-08. A UDP
flow that has had a reply and ICMP other than echo requests are left alone
on purpose: with the chain in `FORWARD`, a limit on every UDP packet would
cap all the UDP of a LAN at 100 packets a second, and one on every ICMP
packet would cap the replies to the LAN's own pings.)

This is the exception of ADR-0011, and the coexistence ticket 18 cares about
(its checkbox 2): the limits are on SYN, ICMP echo requests and UDP without
a reply, which are packets that do not belong to a **Kết nối đã tăng tốc**.
A forwarded UDP flow that has had its reply is not limited, on the CPU or
accelerated; once accelerated its packets ride the ASK fast path and do not
reach the chain at all.
Connections that terminate on the router are never accelerated
("Proxy, ICAP, captive portal, services on the router" in the spec), so
traffic to the router is always subject to the limit. The UI note that the
limits apply only to packets outside a Kết nối đã tăng tốc is bmcwebUI ticket
`02`.

### The dashboard numbers under acceleration

The web UI dashboard reads `backend/scripts/network/get_net_stats.sh`, which
reports:

- **connection counts** (total, TCP, UDP) from `conntrack -L`. An
  accelerated connection stays in the conntrack table — the hardware offload
  does not remove it — so it is counted like any other. The counts stay
  correct while acceleration is on. (After a *runtime disable* the entries
  that were accelerated keep `[PERMANENT]` and do not expire until enable or
  reboot; that open limit is noted in ticket `08`, not here.)
- **per-interface bytes** from `/proc/net/dev`. The ASK kernel feeds the
  hardware-forwarded bytes of a **physical** interface (Ethernet, VLAN,
  PPPoE, tunnel) into `dev_get_stats` through cdx's
  `virt_iface_stats_callback`, so the counters of `eth0`…`eth5` include what
  the hardware carried, not only what reached the CPU. The acceptance item
  reads the wan port and the `br-lan` ports, which are physical and so
  covered. (The bridge device `br-lan` itself is not a physical port and is
  not asserted.)

Nothing in the firmware shows **per-connection** byte counters taken from
conntrack: `get_net_stats.sh` is the only reader of `conntrack -L`, and it
uses it for connection counts and a per-source-IP **session** count only,
never the `bytes=` fields (ticket 18, checkbox 5).

`acceptance.sh` has the items `stats` and `stats-back`: PC1 sends to PC2 as
in `brlan-wan` with a low-rate UDP flow beside it, the run is accelerated,
and the item checks the dashboard script's connection counts against the
kernel's table and its per-interface byte growth against what iperf3 carried
(`bench.md`). `tests/qemu-test.sh` runs `stats` against the image to prove
the script and the parsing work on the new base; QEMU has no hardware
counters, so there the item fails on the acceleration state only.

## The captive portal and the proxy

Also from the 24.10 firmware (ticket 13):

- **Captive portal**: CoovaChilli with its kernel match (`kmod-ipt-coova`),
  FreeRADIUS with the SQLite user database, and the security mode logic of
  `/etc/init.d/system` (nac, fido, off). The pages and scripts of the portal
  came with `uhttpd` (above).
- **Proxy**: squid with the BMC configuration (intercept on 3128, HTTPS
  intercept with certificate generation on 3129, ICAP), the ICAP server
  `c-icap`, and its antivirus service `squidclamav`.
- **`http-file-tracker`**, which logs the HTTP file transfers it sees on
  `br-lan` for the clients it is given.

| package | 24.10 tree | this branch |
|---|---|---|
| `coova-chilli` | 1.6, `package/coova-chilli` | 1.7, the package of the v25.12.5 feed copied to `package/coova-chilli`, with the BMC patch 101, the BMC `files/` and the three install lines for them. The kernel module builds on kernel 6.12 with the patches of the feed. |
| `freeradius3` | 3.2.5, `package/freeradius3` | 3.2.8, the feed package copied to `package/freeradius3`, with the BMC sites, SQL module, `radiusd.init`, `freeradius3_db_init`, the SQLite schema and the `rfc4818` dictionary |
| `squid` | 6.11, `package/community/squid` | 7.1, the feed package copied to `package/community/squid`, with the BMC `squid.conf`, `squid.init`, CA files and `update_squid_conf.sh`. Not carried: the `squid-mod-cachemgr` package (squid 7 has no `cachemgr.cgi`) and the 6.11 build fixes. |
| `c-icap`, `squidclamav` | `package/community`, source by git into `dl/` | the same packages, their tarballs next to the Makefiles (`dist/`) with a hash |
| `http-file-tracker` | 0.1.0, a tarball expected in `dl/` that is in no tree | 0.1.1, the release tarball of the tracker's own repository, in `dist/` |
| `clamav` | not selected | not selected |

`build.sh` removes the feed's `coova-chilli`, `freeradius3` and `squid`
from the build, as it does for `node`: two packages of one name cannot both
be built.

**A new board is in security mode nac**, as on the 24.10 firmware: the DHCP
server of `br-lan` is off, CoovaChilli hands out 192.168.182.0/24 on
`br-lan` and sends a client that has not logged in to
`http://bmc.lan/portal.html`; FreeRADIUS checks the login. The mode is
changed on the security page of the web UI. A card that keeps its
configuration through a sysupgrade keeps its mode.

What this means for hardware acceleration:

- In mode nac the traffic of a LAN client goes through CoovaChilli, a
  process: it is read from `br-lan` and sent on through the tunnel device
  `tun0`. The hardware cannot forward a connection whose one end is a
  tunnel device, so in mode nac a client that has logged in is expected to
  be forwarded by the CPU, at the speed of the 24.10 firmware. This is read
  from how the portal works, not measured on the board. Hardware
  acceleration forwards `br-lan` in the modes off and fido.
- Traffic of the proxy ends on the board (squid answers the client and
  opens its own connection to the server) and is never accelerated.
- `http-file-tracker` reads `br-lan` on the CPU. A download that hardware
  acceleration forwards does not pass there after its first packets, so the
  tracker is expected to miss it or to log it short. This is read from how
  the two work, not measured on the board; `acceptance.sh proxy` prints what
  the tracker logged for such a download. Not decided: what the tracker
  should do on a board with hardware acceleration on.

The antivirus chain is as on the 24.10 firmware: squid and `c-icap` start at
boot, and LAN traffic is only sent to squid (ports 80 and 443) once
`clamav.clamav.enable` is set. Neither image has the `clamav` package.
Without it the chain works up to the scan and no further (seen in
`tests/qemu-test.sh`): squid takes a redirected request and asks the
antivirus service, the service cannot reach ClamAV, and squid, told to let
nothing through unscanned (`bypass=0`), gives the client its error page.
So on this image, as built, no HTTP traffic can pass through the proxy.

FreeRADIUS 3.2.8 stops at start without the legacy provider of OpenSSL; the
feed package does not ask for it, the copy here does (`libopenssl-legacy`).

### Checking them

- `check-image.sh` looks for the programs, services and configuration.
- `tests/bmc-packages-test.sh` runs them from the built root filesystem:
  each says its version and finds its libraries, FreeRADIUS reads its whole
  configuration with the user database, squid parses the BMC configuration
  and makes its certificate database.
- `tests/qemu-test.sh` boots the image in mode nac: a LAN client gets its
  address from the portal, is stopped, logs in, gets out and is stopped
  again after the logout (`acceptance.sh portal`); in mode off a download is
  sent to squid, which asks the ICAP server, and a forwarded download is
  logged by the tracker (`acceptance.sh proxy`).
- `acceptance.sh portal` and `proxy` run against the board (bench.md, "Captive portal và proxy"). Every other item switches a board in mode
  nac or fido to off for its run and puts the mode back.

## Acceptance of Mốc A1

`scripts/hwaccel/acceptance.sh` has an item for every criterion of ticket
11; bench.md, "Lần nghiệm thu Mốc A1", lists the steps on the board.
Two items exist for that run only and are run when named: `soak` (one hour
of accelerated traffic, with the board read every five minutes and compared
at both ends) and `reboots` (20 boots in a row, each checked and measured).

## Updating a board: sysupgrade or the SD card

The card has more on it than `sysupgrade` writes:

| On the card | Where | Written by `sysupgrade` |
|---|---|---|
| boot loader (BL2, FIP) | 4K to 5M | no |
| U-Boot environment, with the MAC addresses | 5M | no |
| FMan microcode | 9M | **no** |
| kernel (`fitImage`) | partition 1 | yes |
| root filesystem | partition 2 | yes; the configuration is carried over |

**`sysupgrade` never changes the FMan microcode.** A board keeps the
microcode its card was written with, whatever firmware is installed later.
To change the microcode, write the whole card again with the
`sdcard.img.gz` of a build that has the new one. Writing the card also
replaces the U-Boot environment and the configuration: save the
configuration first (`sysupgrade -b /tmp/backup.tgz`, copy the file away) and
put it back after the first boot (`sysupgrade -r`).

A backup carries the image version of the firmware it was made on, in
`/etc/config/system`. Restored on a firmware of this base, a backup made on
the 24.10 firmware puts 2.0 back, and the board then refuses every later
update of this base. After restoring such a backup:

```
uci set system.@system[0].compat_version=3.0
uci commit system
```

Whether the rest of a 24.10 configuration suits this base is not a question
of this section.

### Between two firmwares of this base

`sysupgrade <image>-sysupgrade.bin` works as on the 24.10 firmware: kernel
and root filesystem are replaced and the configuration is kept. Hardware
acceleration keeps working because the microcode on the card is already the
ASK one.

### From the 24.10 firmware: refused

A board on the 24.10 firmware has the public microcode 106.x on its card.
Installed over it with `sysupgrade`, a firmware of this base would boot with
that microcode and never accelerate. So the image refuses to be installed
there. `sysupgrade -T <image>` (test mode, writes nothing) and a plain
`sysupgrade <image>` both end with:

```
The device is supported, but this image is incompatible for sysupgrade based on the image version (2.0->3.0).
This firmware is on the hardware acceleration base. It needs an FMan microcode and MAC addresses that sysupgrade does not write. Write the whole SD card image instead.
Image check failed.
```

A firmware of this base is installed by writing the SD card, or in
production.

How it works: an image carries an image version (`compat_version` in its
metadata) and a board knows its own (`system.@system[0].compat_version`).
`sysupgrade` refuses an image whose major version differs from the board's.

| Firmware | Image version |
|---|---|
| 24.10, LS1046A-RDB SD boot | 2.0 |
| this base, LS1046A-RDB SD boot | 3.0 |

The image side is `Device/hwaccel-base` in
`target/linux/layerscape/image/Makefile`; the board side is
`target/linux/layerscape/base-files/etc/uci-defaults/05_fix-compat-version`.
The two must name the same version. `check-image.sh` reads the version and
the message back from the built image, and `tests/sysupgrade-test.sh` asks
the 24.10 firmware and the firmware of this base whether they take it.

Limits:

- The message is what the `sysupgrade` command prints. The web UI of the
  24.10 firmware starts `sysupgrade` in the background and reports that the
  upgrade was scheduled; there the refusal is only in
  `/tmp/firmware_upgrade.log` on the board, and the board simply keeps
  running the 24.10 firmware. That web UI is on boards already and is not
  changed by this branch.
- `sysupgrade -F` skips this check, on the 24.10 firmware as anywhere. Do not
  use it to get from 24.10 to this base: the board would run without
  hardware acceleration and with the MAC addresses of the old card.
- A card written with an image of this branch from before the image version
  became 3.0 refuses the newer images in the same way. Write that card once
  more.
- If a later firmware of this base needs another microcode, raise the image
  version again (4.0) with a message that says so; `sysupgrade` cannot
  deliver the microcode.

`sysupgrade` on an SD boot board writes the first two partitions of the disk
it booted from. Before this branch the paths `/dev/mmcblk0p1` and
`/dev/mmcblk0p2` were fixed in `lib/upgrade/platform.sh` and
`lib/preinit/79_move_config`; they are now looked up from the boot device,
which is what lets `tests/qemu-test.sh` run a whole upgrade on a virtio
disk. On the board the result is the same two partitions.

The steps on the board are in `bench.md`.

## DynRouting and Multi-WAN

`package/bmc/bmcDynRouting` and `package/bmc/bmcMultiWAN` are the packages
of the 24.10 tree (branch `multi-wan`), kept the same on both bases: a
change made here is made there too, and their golden tests must pass on
both. FRR and mwan3 come from the packages feed of v25.12.5, which has
newer versions than the 24.10 firmware:

| | 24.10 tree | this branch |
|---|---|---|
| FRR | 10.2.1 | 10.4.1, with two fixes of ripd (`package/frr`) |
| mwan3 | 2.11.16 | 2.12.0 (needs `rpcd`, for its ubus status in ucode) |
| busybox | 1.36.1 | 1.37.0 |
| C library | glibc | musl |

What the newer versions changed for the two packages:

- busybox 1.37 reads a backslash in the replacement of awk's `gsub` the
  POSIX way. The JSON escaping of both CLIs was written with `gsub` and
  lost the backslash before `"` and `\` on this base, which made their
  output invalid JSON. Both now escape character by character.
- FRR 10.4 takes RIP timers from 1 to 32767 seconds (10.2: from 5 up).
  `bmcdynrouting rip set` takes 5 to 32767 on both bases.
- ripd of FRR 10.4.1 neither announces nor accepts a default route (its
  check of a destination refuses 0.0.0.0), and flushes a RIP route 240 s
  after its timeout where 10.2.1 did after 120 s. Upstream undid both
  after 10.4.1. `package/frr` is the feed package of v25.12.5 with those
  two commits of `stable/10.4` as patches 100 (`93bed101`, "ripd: Fix
  default-route accept and announce") and 101 (`58950e39`, the revert of
  the 240 s default); `build.sh` and `scripts/dynrouting-cluster build`
  take the feed's `frr` out of the build. Drop `package/frr` when the feed
  moves to a FRR release that has both.

### Multi-WAN next to hardware acceleration

A Kết nối đã tăng tốc leaves through the WAN that mwan3 chose for it: the
daemon asks the kernel for the route with the mark the packets of the
connection carry, which is the mark of that WAN (mask `0x3F00`). This is
read from the sources of the daemon and of the kernel patch; `acceptance.sh
mwan` shows it on the board.

mwan3 leaves an open connection on its WAN when that WAN is Mất Internet:
it changes neither a route nor an `ip rule`, only the chains that choose a
WAN for new connections. The daemon follows routes, so nothing tells it,
and the hardware would keep forwarding the connection into that WAN for as
long as its sender goes on. When a WAN loses its link mwan3 removes the
routing table of the WAN, and the daemon would move the connection to the
route of the main table: out of another WAN, with the source address of
the lost one.

So `bmcmultiwan event`, which mwan3 runs at every Chuyển WAN, deletes the
conntrack entries that carry the mark of a WAN that is Mất Internet or
lost its link (`/usr/lib/bmcMultiWAN/flush.sh`):

```
conntrack -D --mark 0x200/0x3f00       # wan2, the second interface of /etc/config/mwan3
```

The daemon takes a connection out of the hardware when its conntrack entry
goes. What the sender transmits next is a new connection for the router,
which mwan3 gives to the WAN that now carries the Chính sách WAN. A UDP
flow goes on through that WAN; a TCP connection is reset by its server,
which sees another source address, and the application opens a new one.
Syslog gets a second line at such a Chuyển WAN:

```
bmcMultiWAN: Chuyển WAN: wan2 is Mất Internet; Chính sách WAN default_policy now uses wan, ...
bmcMultiWAN: Chuyển WAN: 12 connections through wan2 removed, so that none stays accelerated towards it
```

- Only while the daemon of hardware acceleration runs. Without it (the
  feature disabled or unavailable, and the 24.10 firmware, which has the
  same package) nothing is deleted and an open connection stays on its
  WAN until it ends, as mwan3 has it.
- Every connection with the mark goes, also one kept on the CPU and one
  that came in through that WAN (a port forward): which entries are in the
  hardware cannot be asked per WAN.
- A WAN that has Internet again loses nothing: open connections stay on
  the WAN they use, new ones follow the Chính sách WAN.
- A restart of mwan3 (every change of a WAN, a Chính sách WAN or a Luật
  chọn WAN) is not a Chuyển WAN and deletes nothing. For the about 2 s of
  the restart mwan3 has no routing tables, and marked packets follow the
  main table on the CPU; the daemon looks routes up again when a table
  goes, so the hardware should do the same (read from its source, not
  measured).

Tests: the golden tests of the CLI (`event-*-accelerated`,
`event-lost-run`); `tests/qemu-test.sh` runs the `mwan` and `mwan-in`
items with a service that stands in for the daemon, so the deletion and
the move of a flow to the other WAN are run with the image's own mwan3 and
conntrack; whether the hardware lets go of the connection is only seen on
the board (`bench.md`, "Multi-WAN với hai WAN").

Tests: `tests/routing-cli-test.sh` (in `build.sh test`) runs the golden
tests of both CLIs with the busybox of the built image; with
`ROOTFS=<root-layerscape of a 24.10 tree>` it runs them with that busybox.
`scripts/dynrouting-cluster` and `scripts/multiwan-cluster` run both
features for real on QEMU guests of an `armsr/armv8` image built from this
tree (`dynrouting-virtual/README.md`, `multiwan-virtual/README.md`); they
do not test hardware acceleration.
