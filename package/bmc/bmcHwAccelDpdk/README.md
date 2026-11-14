# bmcHwAccelDpdk

Phần hiện thực của Tăng tốc phần cứng trên các board DPAA2 (LS1088). Spec:
`.scratch/hw-accel-ls1088/spec.md` của repo chính, mục Engine; ADR-0012.

Gói có `bmchwaccel-engine`: chương trình C, link tĩnh DPDK của gói `dpdk`.
Engine giữ hai cổng 10G. Nó tự chuyển các gói của Kết nối đã tăng tốc (IPv4
TCP/UDP), ngoài firewall và qdisc của Linux. Mọi gói khác nó đưa lên kernel.
Daemon `bmchwaccel-syncd` đọc conntrack và giao kết nối cho engine, rồi rút về.

Hiện có:

- lõi xử lý gói (ticket `07`);
- engine với cổng ethdev bất kỳ, socket điều khiển (ticket `07`);
- worker eventdev, link phía kernel theo cáp, bắt gói bằng `dpdk-pdump` (ticket `04`);
- bố cục engine lúc boot: container của engine, hugepage, init script (ticket `04`). Gói có trong image đầy đủ của LS1088.
- `bmcHwAccel` điều khiển engine (ticket `05`): `bmchwaccel` bật/tắt, `status` có `reboot_required`, dấu boot, engine chết thì được khởi động lại, chết liên tục hay không lên được thì router tự khởi động lại sang bố cục kernel. Client `bmchwaccel-ctl` của socket điều khiển.
- thống kê và trạng thái cổng trên dây (ticket `06`): lệnh `ports` của engine, `bmchwaccel ports`. Xem mục Thống kê và bắt gói.
- daemon đồng bộ `bmchwaccel-syncd` (ticket `08`): route + NAT IPv4 TCP/UDP giữa hai cổng của engine được tăng tốc. Xem mục Daemon đồng bộ.
- chung sống với Feature BMC (ticket `09`): route, rule, neigh đổi hay một interface xuống thì engine rút các kết nối đi đường đó (mục Khi routing đổi); `bmcMultiWAN` hỏi `bmcHwAccel` (`/usr/lib/bmcHwAccel/daemon-running`) thay cho tên `cmm`.
- VLAN và PPPoE trên đường tăng tốc (ticket `10`): LAN là interface VLAN, WAN là PPPoE, hay cả hai. Xem mục VLAN và PPPoE.
- ESP trên SEC (ticket `14` của `.scratch/hw-accel-ls1088`, spec `spec-ipsec.md`): DPSECI riêng trong container của engine, `crypto_dpaa2_sec` mỗi worker 2 queue pair, kết quả về thành event của worker; seam "ESP ops" có credit theo SA, bản thật trên SEC và bản test bằng OpenSSL. Chưa có đường gói nào dùng: Tunnel IPsec vẫn đi kernel. Xem mục ESP.
- engine giữ dãy số ESP (ticket `15`): `bmchwaccel-syncd` đọc SA của Tunnel IPsec qua `NETLINK_XFRM` và giao cho engine; engine đánh số lại mọi ESP kernel gửi ra trên SA ra nó giữ (kể cả ESP kernel phân mảnh ra), daemon ghi số của engine + `2^24` vào `oseq` của kernel mỗi 1 s và cộng bộ đếm mỗi 5 s. Traffic của tunnel vẫn do kernel mã hoá và giải mã. `bmchwaccel status` có `ipsec_sa`, lệnh mới `bmchwaccel sa`. Xem mục Tunnel IPsec.
- kết nối qua Tunnel IPsec được tăng tốc (ticket `16`): engine tự giải, chuyển và mã gói của kết nối đã giao. Xem mục Tunnel IPsec.
- rekey, rơi về kernel và các giới hạn (ticket `17`): rekey chuyển kết nối của tunnel sang SA mới mà không rút; kết nối engine rút vì tunnel mất SA ra được báo cho daemon để giao lại; engine không đánh số quá `2^32 − 2^26`, daemon trả SA về kernel trước đó; tunnel quá giới hạn và thuật toán SEC không làm được đi kernel. Xem mục Tunnel IPsec, Daemon đồng bộ.

## Cấu trúc

| File | Nội dung |
|---|---|
| `src/core.h`, `src/core.c` | Lõi: parse, bảng kết nối, NAT, TTL, checksum, học đường ra, giao/rút kết nối. Không I/O, không gọi API DPAA2 |
| `src/engine.c`, `src/engine.h` | `main`: tham số, EAL, cổng, worker, luồng điều khiển |
| `src/ctl.c`, `src/ctl.h` | Giao thức của socket điều khiển |
| `src/esp.h`, `src/esp.c` | Seam "ESP ops": SA, credit theo SA trong mỗi worker, hàng chờ, bộ đếm; trên một backend. Không gọi API DPAA2 |
| `src/esp_sec.c` | Backend thật: SEC qua `crypto_dpaa2_sec` (`rte_security`, lookaside protocol), gắn queue pair vào eventdev |
| `src/ipsec.h`, `src/ipsec.c` | Tunnel IPsec trong engine: bảng SA và tunnel, đánh số lại ESP kernel gửi ra, ghép và phân mảnh lại ESP phân mảnh, rút SA có trật tự. Trên "ESP ops", không gọi API DPAA2 |
| `src/ctl-client.c` | `bmchwaccel-ctl`: một lệnh tới socket điều khiển, cho script (busybox không có client socket UNIX) |
| `src/sync.h`, `src/sync.c` | Daemon: quyết định với mỗi kết nối của conntrack (giao, rút, hỏi lại, thử lại, timeout). Không I/O |
| `src/watch.h`, `src/watch.c` | Daemon: một thay đổi của routing (route, rule, địa chỉ, interface, neighbour) bắt engine rút những kết nối nào. Không I/O |
| `src/sa.h`, `src/sa.c` | Daemon: SA nào của xfrm được giao cho engine, lệnh `sa-add` của nó, các SA và tunnel engine đang giữ. Không I/O |
| `src/syncd.c` | `bmchwaccel-syncd`: ctnetlink (libnetfilter_conntrack), rtnetlink, xfrm netlink, phiên với engine, vòng chính |
| `files/bmchwaccel-syncd.init` | Daemon dưới `supervise` của `bmcHwAccel`; `bmcHwAccel` bật/tắt nó, init script tự nó bị tắt như `cmm` |
| `files/layout` | Bố cục của lần boot này (`engine`/`kernel`), cổng và số worker từ UCI, hugepage, dấu boot, lý do không khả dụng |
| `files/container` | Dựng và kiểm container của engine bằng `restool` |
| `files/bmchwaccel-layout.init` | `S11`: quyết bố cục và cấp hugepage lúc boot |
| `files/bmchwaccel-engine.init` | `S91`: kiểm container rồi chạy engine dưới `supervise-engine` của `bmcHwAccel` (không có gói đó thì procd respawn) |
| `tests/run.sh` | Mọi test, một lệnh |
| `tests/unit/` | Seam 1: lõi, trên máy build; "ESP ops" với backend OpenSSL (`esp_test.c`); Tunnel IPsec của engine trên nó (`ipsec_test.c`); phần quyết định của daemon (`sync_test.c`, `watch_test.c`, `sa_test.c`) |
| `tests/esp/` | Backend OpenSSL của "ESP ops" (engine của test link bản này thay `esp_sec.c`); ESP do kernel Linux của mạch tạo (`linux/`, `linux-esp.sh`) |
| `tests/daemon/` | Seam 3: daemon thật với engine giả và conntrack thật trong QEMU |
| `tests/functional/` | Seam 2: engine thật với cổng `net_memif`, đưa pcap vào, so pcap ra |
| `tests/host-dpdk.sh` | Build DPDK cho máy build (container `ubuntu20`) |

## Lõi

- **Hai phía của mỗi cổng.** Mỗi cổng engine có phía dây (`dpni.X`, cáp) và phía kernel (`dpni.Y`, nối với `dpni.Z` = `ethN` của kernel). Lõi biết gói vào từ phía nào nhờ `mbuf.port` (PMD đặt) và bảng `core_map_ethdev()`.
  - Gói từ dây thuộc một Kết nối đã tăng tốc: sửa rồi ra dây của cổng mà entry chỉ.
  - Gói từ dây khác: lên phía kernel của cổng vào, không đổi.
  - Gói kernel gửi: ra dây của cùng cổng, không đổi.
  - Thứ tự gói lên kernel trong một burst được giữ.
  - Gói của một ethdev chưa khai báo bằng `core_map_ethdev()` bị bỏ.
- **Gói luôn lên kernel:**
  - không khớp bảng;
  - TCP SYN, FIN, RST;
  - fragment, IP options;
  - TTL ≤ 1;
  - vượt MTU của cổng ra (so với độ dài frame trừ header L2 vào; ra PPPoE thì MTU bớt 8 byte);
  - header ra dài hơn header vào mà mbuf không đủ chỗ phía trước frame (headroom);
  - MAC đích multicast/broadcast;
  - IP đích từ `224.0.0.0` trở lên;
  - không phải IPv4 TCP/UDP: ARP, ICMP, IPv6;
  - VLAN và PPPoE khác những gì mục VLAN và PPPoE nhận; VLAN 4095 (802.1Q dành riêng, khóa của gói giải từ tunnel dùng nó);
  - frame nhiều segment, frame ngắn hơn độ dài IP;
  - gói phần cứng báo sai checksum.
  - Engine không lọc MAC unicast lạ: `dpaa2-eth` trên `dpni.Z` làm việc đó.
- **Khóa của bảng** (chốt ở ticket này): 16 byte, hàm hash CRC32C.
  - IP nguồn, IP đích, port nguồn, port đích như trên dây;
  - một từ 16 bit: bit 15 là UDP, bit 12–14 là cổng vào, bit 0–11 là VLAN (0: không có tag);
  - session PPPoE (0: không có PPPoE).
  - Gói giải ra từ Tunnel IPsec: cổng vào là cổng ESP vào, VLAN là 4095, chỗ của session PPPoE là số tunnel. Gói từ tunnel khác không bao giờ khớp entry của tunnel này.
- **Entry:** một cache line: tuple sau NAT, delta checksum IP (gồm TTL−1) và L4, MTU, cổng ra, độ dài header L2 vào, header L2 ra (tới 26 byte) và chỗ của độ dài PPPoE trong đó, bộ đếm gói/byte, thời điểm gói cuối.
- **Học đường ra** (ADR-0012):
  - Gói từ dây không khớp, hoặc SYN/FIN/RST, ghi "tuple này vào từ cổng này".
  - Gói kernel gửi ghi "tuple này ra cổng này, với header L2 này" (Ethernet, tag VLAN, header PPPoE như kernel gửi).
  - Bản ghi "vào" giữ VLAN và session của gói, để entry chỉ khớp gói của đúng VLAN và session đó.
  - Worker gửi bản ghi qua ring riêng; luồng điều khiển giữ bảng học: tối đa `--learn-max` bản, mỗi bản dùng được `--learn-ttl` ms, đầy thì bỏ bản cũ nhất.
  - Chưa lọc bản ghi lặp ở worker: kết nối không bao giờ được giao (cổng 1G, IPsec, giữ trên CPU) sinh hai bản ghi mỗi gói. Đáng làm khi đo CPU của luồng điều khiển (ticket `08`/`09`).
- **Giao kết nối** (`core_bind`, tuple gốc và tuple reply như conntrack):
  - đủ bốn bản học (gốc vào, gốc ra, reply vào, reply ra) thì tạo hai entry;
  - thiếu thì từ chối, nói thiếu bản nào. Kết nối có một đầu ở cổng 1G thiếu "gốc vào" và "reply ra".
  - Tuple đã thuộc entry khác thì từ chối, không bao giờ ghi đè.
- **Rút** một kết nối, rút hết, rút theo cổng, theo mạng đích, theo MAC đích: các bản học liên quan cũng bị quên, để lần giao sau dùng đường ra mới.
  - theo cổng (`core_flush_port`): kết nối vào hay ra cổng đó, mọi bản học của cổng;
  - theo mạng đích (`core_flush_route`): kết nối có một chiều mà gói ra (sau NAT) tới một địa chỉ của mạng đó; bản học "ra" tới mạng đó. `/0` là mọi kết nối;
  - theo MAC đích (`core_flush_mac`): kết nối có một chiều mà header L2 ra mang MAC đó; bản học "ra" tới MAC đó.
- **Đồng thời:** worker đọc bảng (`rte_hash`, `RW_CONCURRENCY_LF`) không khóa. Luồng điều khiển xóa entry qua hàng đợi trì hoãn của RCU (`rte_rcu_qsbr_dq`): ô khóa và action chỉ được dùng lại khi mọi worker đã qua trạng thái tĩnh. Worker gọi `core_worker_quiescent()` mỗi vòng; trước khi ngủ thì `core_worker_offline()`.

## VLAN và PPPoE

Ticket `10`; spec, mục Engine (phạm vi tăng tốc: LAN là `br-lan` hoặc interface VLAN, WAN là cổng thường hoặc PPPoE).

- **Header L2 engine nhận** (cả gói vào lẫn gói kernel gửi): Ethernet, rồi tùy chọn một tag 802.1Q, rồi tùy chọn header PPPoE session, rồi IPv4. Tức bốn dạng: 14, 18, 22, 26 byte. PPPoE trên VLAN của WAN (như một số ISP) là dạng 26 byte.
- **Lên kernel** (không bao giờ tăng tốc): hai tag (802.1Q trong 802.1Q), 802.1ad, VLAN 0 (tag chỉ có priority), session 0, PPPoE không phải version 1 type 1 code 0, PPP khác IPv4 (LCP, IPv6…), độ dài PPPoE khác độ dài gói IPv4 cộng 2, PPPoE discovery. VLAN 0 và session 0 sẽ có khóa trùng với gói không tag, không PPPoE, nên bị loại.
- **Khóa:** VLAN id (bỏ 3 bit priority) và session như trên dây. Cùng tuple trên VLAN khác, session khác là kết nối khác. Bit priority của gói vào không đổi gì; gói ra mang tag kernel đã gửi.
- **Sửa gói:** IP và L4 sửa như cũ (checksum không đổi vì header L2), rồi frame bắt đầu ở `l2_len` byte trước header IPv4, chép header L2 ra, ghi độ dài PPPoE (độ dài IPv4 + 2) khi ra PPPoE. Frame ra kết thúc ở cuối gói IPv4: padding của frame ngắn không đi theo. Ethernet vào và ra (đường của gần như mọi gói) vẫn chỉ chép 14 byte, không đổi độ dài.
- **MTU:** `--port` cho MTU của cổng (1500). Ra PPPoE: gói IPv4 tối đa MTU − 8 (1492, MTU của `pppoe-wan`). Tag VLAN không tính vào MTU (MTU của `eth1.30` là 1500).
- **PPPoE quay số lại:** `pppoe-wan` mất (interface bị xóa, hay xuống) nên daemon bắt engine `flush` (mục Khi routing đổi). Kết nối mới học header của session mới từ gói kernel gửi; gói còn tới trong session cũ lên kernel.
- **Giới hạn:**
  - MTU của `pppoe-wan` hay interface VLAN đặt nhỏ hơn mặc định trong UCI (ví dụ ISP đòi 1480) thì engine không biết: nó dùng MTU của cổng (trừ 8 cho PPPoE). TCP không bị ảnh hưởng khi zone `wan` có `mtu_fix` (mặc định của OpenWrt): fw3 kẹp MSS theo MTU của interface lúc SYN qua kernel; gói UDP lớn hơn MTU đó vẫn được engine gửi.
  - RSS của DPAA2 với frame PPPoE: chưa đo phần cứng có băm theo tuple IP bên trong PPPoE không. Nếu không, mọi luồng PPPoE vào một worker (vẫn đúng thứ tự, chỉ chậm hơn ở 10G). Đo ở ticket `12`.
  - Chu kỳ/gói của đường Ethernet thường sau ticket này chưa đo lại trên mạch (`enginebench`). Đường đó thêm một so sánh ethertype, một so sánh headroom và một so sánh độ dài header, đều đoán trước được.

## Engine

```
bmchwaccel-engine EAL-ARGS -- --port NAME,WIRE,KERNEL[,MTU] ... [--conns N]
    [--learn-max N] [--learn-ttl MS] [--socket PATH] [--event] [--sas N] [--tunnels N]
    [--tx-limit NAME,MBPS] ...
```

- `--port`: tên cổng của kernel (`eth0`), ethdev phía dây, ethdev phía kernel, MTU (mặc định 1500). Thứ tự là số cổng.
- Lcore chính phục vụ socket điều khiển. Mỗi lcore còn lại là worker w: lấy hàng đợi Rx thứ w của mọi ethdev (RSS chia luồng), gửi trên hàng đợi Tx thứ w.
  - Không có `--event`: worker poll, bận 100 % cả khi rảnh. Dùng cho test (`net_memif`).
  - `--event` (trên mạch): Rx adapter đưa hàng đợi Rx w của mọi ethdev vào event queue parallel w, chỉ worker w nối queue đó. Worker ngủ trong `rte_event_dequeue_burst` (timeout 100 ms), RCU offline trong lúc ngủ. Rảnh 60 s: mỗi core worker bận dưới 1 %.
- Mỗi hàng đợi 512 descriptor Rx, 512 Tx. Trên DPAA2, số Rx là tail drop của hàng đợi; 16 hàng đợi × 512 dưới mức 11264 mà PMD dpaa2 cảnh báo.
- **Link:** cứ 100 ms lcore chính đọc link phía dây và bật/tắt phía kernel theo (`rte_eth_dev_set_link_up/down` = `dpni_enable/disable`). `dpni.Z` của kernel vì thế chỉ có carrier khi cáp có: rút cáp `eth0` thì `eth0` mất carrier, netifd và mwan3 thấy. Mỗi lần đổi in ra `ethN: cable up/down`.
- **Bắt gói:** engine gọi `rte_pdump_init()`, worker gọi callback Rx của pdump (eventdev đi vòng qua `rte_eth_rx_burst`). Xem mục Thống kê và bắt gói.
- `--sas`: số SA của ESP engine giữ (mặc định 24576: 4096 tunnel, mỗi tunnel 6 session lúc rekey). Xem mục ESP.
- `--tunnels`: số tunnel engine giữ, tối đa và mặc định `IPSEC_MAX_TUNNELS` = 4096 (Q16). Chỉ để test đặt nhỏ hơn (seam 2, kịch bản `ipsec-tunnels`).
- `--tx-limit NAME,MBPS` (ticket `21`): phía cáp của cổng NAME gửi tối đa MBPS (8–10000), đều, không theo chùm 10G.
  - Dùng khi cổng SFP+ cắm module hạ tốc (10GBASE-T xuống 1G) mà module không gửi PAUSE. Engine cho mỗi worker một hàng đợi TX, nên nhiều luồng cùng lúc thành chùm 10G vào module. Module làm hỏng khung: máy bên kia thấy lỗi CRC (0,3–0,4 % với PC4 sau module 10G, ngày 2026-11-03).
  - Trước khi cổng chạy, traffic manager của DPAA2 (`rte_tm`) đặt shaper ở gốc (LNI) và ở từng kênh của DPNI phía cáp, cùng mức, chùm 3000 B. Chỉ shaper gốc thì MC nhận nhưng không có tác dụng khi DPNI có nhiều kênh. Chỉ shaper kênh thì hàng đợi của các worker vẫn cộng lại quá mức.
  - **Bước 8 Mbps:** PMD dpaa2 đưa MC `(byte/s / 2^20) × 8` Mbps, nên mức chỉ đi theo bước 8. Engine hạ MBPS xuống một bước (980 thành 976) và log mức thật. Dưới 8 thì MC nhận 0, tức không giới hạn: engine và `layout` không nhận.
  - 24 B mỗi khung (preamble, khoảng nghỉ, FCS) chỉ được PMD cộng cho shaper gốc, mà shaper gốc không có tác dụng. Shaper kênh đếm byte của khung, không đếm 24 B đó: với khung 1514 B, 976 Mbps khoảng 991 Mbps trên cáp. Khung nhỏ dồn dập thì trên cáp có thể quá 1G.
  - Áp được thì log `eth0 sends at most 976 Mbps (4 channels; 980 asked, in steps of 8)`, hay `... at most 960 Mbps (4 channels)` khi MBPS đúng bước. Thiết bị không có TM (`net_memif`) thì `eth0 sends without its limit of 980 Mbps: ...`, và cổng chạy không giới hạn. Tên cổng hay số sai thì engine dừng, như `--port` sai.
  - Nên đặt hơi dưới tốc độ của link bên kia, ví dụ 980 (976) cho 1G: không còn lỗi CRC, nối thẳng `-P 4` lên 918–919 Mbps (trước đó 821–842).
- Giao thức của socket điều khiển (dòng chữ, phiên bản 1): đầu `src/ctl.c`. Lệnh: `bind`, `unbind`, `flush`, `flush-port`, `flush-route`, `flush-mac`, `count`, `list`, `stats`, `ports`, `claim`, `claimed`, `active`, `esp`, `sa-add`, `sa-stop`, `sa-del`, `sa-flush`, `sa`. `flush-port`, `flush-route`, `flush-mac` liệt kê từng kết nối đã rút (`conn tcp|udp OSIP OSPORT ODIP ODPORT`) trước `ok N`; `sa-stop`, `sa-del`, `sa-flush` cũng vậy với kết nối mà tunnel rút vì không còn SA ra (sau dòng của SA).
- **Phiên của daemon:** daemon gửi `claim` trên phiên của nó; mỗi lúc chỉ một phiên giữ được engine (`err claimed`). Phiên đó đóng (daemon dừng, chết, kể cả `kill -9`) thì engine rút hết kết nối (`core_flush`), in `the daemon's session closed: N connections go through the kernel again`: không còn ai rút kết nối khi chúng kết thúc hay khi `sweep`, nên chúng đi tiếp qua kernel (Q7). Engine cũng rút hết SA của Tunnel IPsec (`... N SAs of Tunnel IPsec go through the kernel again`): không còn ai ghi số của nó vào kernel. `claimed` cho `bmcHwAccel` biết daemon có đang giữ engine không.
- `active MS`: các kết nối đã chuyển ít nhất một gói trong MS ms qua, kèm `idle` (ms từ gói cuối, chiều nào cũng được). Daemon dùng để gia hạn conntrack.

## ESP

Spec `.scratch/hw-accel-ls1088/spec-ipsec.md` (Engine: DPSECI, Cryptodev, Hugepage), ticket `13` (số đo SEC), ticket `14`. Đường gói dùng nó: mục Tunnel IPsec (ticket `15`).

**Seam "ESP ops"** (`src/esp.h`):

- SA ở đây là một session: một chiều của ESP (mã gói thành ESP, hoặc giải ESP thành gói) với một bộ khoá. Tunnel mode IPv4, ESP thường hay ESP trong UDP; AES-CBC 128/256 + HMAC-SHA1-96/256-128/384-192/512-256, AES-GCM 128/256 (ICV 16). Số SA do engine đặt, `0` tới `--sas` − 1.
- Worker gọi `esp_submit()` (job: gói, SA, `dst` khi out-of-place) và nhận kết quả của chính nó: event của event queue của nó (`esp_events()`), hoặc `esp_poll()`. Luồng điều khiển thêm/xoá SA (`esp_sa_del` trả `-EBUSY` khi SA còn job).
- Hai backend: `src/esp_sec.c` (SEC), `tests/esp/esp_openssl.c` (OpenSSL, engine của test và `esp_test`). Bản OpenSSL giải đúng ESP do kernel 6.12 của mạch tạo cho cả 6 thuật toán và có header ngoài như SEC tạo (TTL 64, DSCP và DF của gói trong, IP id mỗi SA từ 0, checksum UDP 0); IV làm từ SPI và số thứ tự, để pcap ra lặp lại được.

**SEC** (`src/esp_sec.c`):

- DPSECI của container (`container build`: 8 queue pair, `DPSECI_OPT_HAS_CG`). Kernel giữ `dpseci.0` của DPL cho IPsec của nó.
- Queue pair `q` của worker `w` là queue pair `w × 2 + q` của DPSECI; chỉ worker `w` enqueue, bằng portal của nó. SA của một lane (`reqid` của tunnel) cùng một queue pair trong mỗi worker, nên hai queue pair chia đôi tunnel của worker.
- `--event`: crypto adapter của `event_dpaa2`, internal port (`dpaa2_sec_eventq_attach`), mode `OP_NEW`: kết quả của các queue pair của worker `w` về event queue `w`, qua DPCON của chính queue đó. Không service core, không poll, không thêm DPCON (78 DPCON của chip trước và sau). Priority của event phải khác 0: `dpaa2_sec` chia cho nó.
- Session: `rte_security`, lookaside protocol; `copy_df` (DF của gói trong, như Linux). `copy_dscp` làm SEC Era 8 báo lỗi mọi gói (`0x40003382`); không có nó SEC vẫn chép DSCP (ticket `13`).
- Số thứ tự đầu của SA ra: `esp_sa_conf.seq`. `dpaa2_sec` gốc luôn bắt đầu từ 1 khi không ESN; patch `003-dpaa2-sec-first-sequence-number.patch` của gói `dpdk` lấy `esn.low` khác 0 làm số của gói đầu (`seq_num` của encap PDB). Bản OpenSSL làm như vậy.
- DPSECI sống lâu hơn engine: sau `kill -9` nó vẫn bật, kết quả của engine cũ có thể còn trong hàng đợi. Engine start rồi stop cryptodev một lần trước khi gắn (`dpseci_disable` + `dpseci_reset`).
- `dpaa2_sec` ghi một dòng ERR cho mỗi gói SEC báo lỗi (ICV sai, replay), theo logtype `pmd.crypto.dpaa2`: init script để logtype đó ở mức `crit`; `esp.c` đếm lỗi theo SA. Logtype chung `pmd` giữ ở `notice`: `dpaa2_sec` chỉ dùng nó cho lỗi lúc dựng queue pair, không cho từng gói.

**Tự kiểm lúc khởi động** (trước khi cổng chạy): mỗi worker mã một gói 100 byte bằng SA ra (aes256-cbc + hmac-sha256-128, ESP trong UDP, như trang VPN) trên từng queue pair của nó, nhận kết quả theo đường kết quả sẽ về (event), giải lại bằng SA vào cùng khoá, so với gói gốc. Hỏng thì engine chạy không có ESP. Kết quả: dòng log `ESP on dpsec-1: 2 queue pairs per worker, results as events, self-test passed` và lệnh `esp` của socket điều khiển:

```
$ bmchwaccel-ctl esp
esp state=ok device=dpsec-1 queue_pairs=2 sas=0 max_sas=24576
ok
```

`state=none`: container không có DPSECI; `state=failed`: không qua tự kiểm.

**Credit theo SA** (ticket `13`, phần 3: chặn đầu hàng trong một queue pair):

- SEC lấy job của một queue pair theo thứ tự; job của một SA chờ khi DECO của SA đó bận. Một SA nhiều job trong queue pair làm mọi SA khác của queue pair chờ sau nó.
- Mỗi SA trong mỗi worker chỉ có tối đa `ESP_SA_BUDGET` = 24 µs việc của DECO trong queue pair (ticket `22`; 6 µs tới đó). Việc một job: `esp_cost()` = 480 ns + 8/3 ns mỗi byte, từ tốc độ một SA trên một DECO của ticket `13` (64 B 0,64 µs, 512 B 1,84 µs, 1400 B 4,2 µs). Tức 6 job ở 1400 B, 14 ở 512 B, 37 ở 64 B.
  - Ticket `13` đo bằng vòng poll kín: 2 job 1400 B đã đủ cho một DECO. Trong engine, job quay về thành event của worker, lâu hơn nhiều, nên cần nhiều job hơn trong SEC.
  - Trên mạch (ticket `22`, một tunnel, `iperf3 -P 4`, CBC, mỗi mức đo 2 lần): 6 µs được 692–855 Mbps và bỏ 0,2 % gói vì hết credit; 12 µs được 691–873 và vẫn bỏ gói; 18 và 24 µs lần nào cũng 873 Mbps, không bỏ gói. Ở 873 Mbps có khoảng 4 job 1400 B đang ở SEC.
  - Chọn 24 thay vì 18 để có dư so với mức 12, mức còn chưa đủ. SA khác cùng queue pair chờ sau SA bận tối đa khoảng một budget (mô hình của ticket `13`). Bench 1G không đo được mức chờ đó, vì hàng đợi của link tính bằng ms: một tunnel nhẹ cùng worker, cùng queue pair (ping) chờ như nhau ở mọi mức, kể cả khi không có credit, vì SA bận chỉ dùng khoảng 1/3 DECO của nó. Tunnel gần trần một DECO (2,67 Gbps) cần nhiều job hơn trong SEC: đo lại ở ticket `20`.
- Job vượt credit vào hàng chờ của SA trong worker (`ESP_SA_WAIT` = 256, tối đa `ESP_WAIT_MAX` = 1024 cho cả worker; 32 lúc đầu, nâng ở ticket `16` vì worker của tunnel nhận loạt gói của mọi worker: 6 % gói mất trên mạch với 32), xuống SEC khi một job của SA quay về; quá nữa thì bỏ và đếm (`dropped`). Thứ tự job của một SA giữ nguyên.
- Credit tính theo SA trong từng worker, không chung giữa các worker: chặn đầu hàng chỉ trong một queue pair, và mỗi queue pair chỉ một worker dùng, nên không cần phép cộng atomic giữa các core (luồng điều khiển chỉ đọc `queued`/`waiting`). Chiều vào của một tunnel luôn về một worker (RSS), và từ ticket `16` mọi gói vào một tunnel do một worker mã. Vì vậy job của một SA chỉ ở queue pair của một worker, và SA khác cùng queue pair chờ sau nó tối đa khoảng một budget (24 µs), vẫn xa mức ms khi không có credit.
- Đo trên mạch 2026-10-29 (`espbench` của `.scratch/hw-accel/ls1088-tools`, dùng `esp.c` + `esp_sec.c` này, 1 worker, poll, aes256-cbc + hmac-sha256, ESP trong UDP; log ở `/root/t14` của mạch):

| Bài | Có credit | Không credit |
|---|---|---|
| 1 SA, 1400 B, đưa vào 300 kpps (3,4 Gbps) | 2,61 Gbps (98 % trần một DECO, 2,67) | 2,61 Gbps |
| SA nóng 1400 B + 3 SA nhẹ 46,5 kpps mỗi SA, cùng queue pair | SA nhẹ nhận đủ, trễ trung bình 9 µs, tối đa 23 µs; SA nóng 2,61 Gbps | SA nhẹ còn 0,1 kpps (bị bỏ vì queue pair đầy), trễ 9,3 ms |
| Như trên, 512 B (SA nóng 700 kpps, SA nhẹ ~16 kpps) | SA nhẹ đủ, trễ 8,7 µs; SA nóng 1,83–1,88 Gbps | SA nhẹ mất 27 %, trễ 3,6 ms; SA nóng 2,15 Gbps |
| Như trên, 64 B | SA nhẹ trễ 10,6 µs; SA nóng 854 kpps (CPU của bài đo) | SA nhẹ trễ 21 µs; SA nóng 873 kpps |

  - Ở 512 B, SA nóng thiếu là do CPU của bài đo (không đưa đủ 700 kpps vào). Budget 9 µs chỉ thêm 2 % (1,93 Gbps).

**Bộ nhớ** (hugepage, `espbench mem`, 4 worker, 24576 SA, đo trên mạch): backend 13,8 MB (pool session, op, FLE của 8 queue pair), lớp `esp` 4,0 MB (trạng thái SA của mỗi worker), session 20,0 MB (832 byte mỗi SA, `dpaa2_sec` cấp bằng `rte_zmalloc` lúc tạo). Tổng 37,8 MB; xoá hết SA thì trả lại đủ. Tạo 24576 SA mất 108 ms. `layout hugepages()` cộng 32 MB + 2 MB mỗi worker.

## Tunnel IPsec

Spec `spec-ipsec.md` (Đường gói ①–④, ESP kernel gửi ra, ESP kernel phân mảnh ra; Engine: Entry kết nối, Bảng tunnel, Số thứ tự, Bộ đếm), ADR-0012, ADR-0014, ticket `15` (dãy số) và `16` (kết nối qua tunnel).

- **SA engine giữ** (`ipsec.c`): daemon giao qua `sa-add` (khoá, địa chỉ, cổng UDP, `reqid`, cửa sổ, số đầu). Tunnel là `reqid`; SA của một tunnel chung lane (queue pair) của "ESP ops". SA ra có hai session: mã (số của engine, từ `seq` của `sa-add`) và "giải lại" (khoá của SA ra, không chống replay). SA vào có một session giải. Tối đa `IPSEC_MAX_TUNNELS` = 4096 tunnel (Q16), `--sas` session.
- **Kết nối qua tunnel** (ticket `16`). Lõi học và giao như kết nối thường (`core_bind` cần đủ bốn bản học), với hai loại bản học mới:
  - **"ra qua tunnel T"**: từ ESP kernel gửi ra trên SA ra T, đã giải lại (`core_learn_tunnel`): tuple của gói trong, cổng và header L2 ngoài của ESP đó, và MTU của gói trong.
  - **"vào từ tunnel T"**: từ gói giải ra của ESP từ dây trên SA vào của T mà không khớp entry (`core_rx_tunnel`).
  - `core_bind` đòi mỗi chiều vào từ đúng tunnel mà chiều kia đi vào (hoặc cả hai không qua tunnel). Bản học "vào từ tunnel" có trước khi kernel kiểm policy, nên gói của tunnel khác mang cùng tuple chỉ làm `bind` bị từ chối (thiếu "reply vào"), không bao giờ gắn kết nối vào tunnel đó.
  - Entry chiều đi có cờ "vào tunnel" (`OUT_TUNNEL` trong `out`, số tunnel ở mảng `tunnel` theo action), header L2 ngoài và MTU của gói trong. Khoá chiều về mang số tunnel (mục Lõi).
- **ESP từ dây** trên SA vào engine giữ (`ipsec_wire`, trước lõi): IPv4 không phân mảnh, ESP thường hay ESP trong UDP đúng nguồn, đích, SPI và cổng; SEC giải out-of-place vào một mbuf mới, bản gốc giữ nguyên. Gói giải ra qua lõi (`core_rx_tunnel`): khớp entry của đúng tunnel thì TTL−1, ra dây cổng của entry (④); còn lại (không khớp, tunnel khác, SYN/FIN/RST, phân mảnh, options, TTL ≤ 1, không TCP/UDP) thì bỏ bản giải, **ESP gốc** lên phía kernel của cổng vào. SEC không giải được (ICV sai, replay) thì ESP gốc cũng lên kernel: kernel quyết. ESP phân mảnh, IKE, keepalive, SPI không giữ, SA vào đã `sa-stop`: lên kernel như mọi gói, không qua SEC.
- **Cửa sổ chống replay 128** (ticket `23`): gói cài `/etc/strongswan.d/bmchwaccel.conf` (`charon { replay_window = 128 }`) cho mọi CHILD_SA. SEC kiểm cửa sổ sau khi các job của một SA đã chạy song song trên các DECO, nên ESP tới chỗ kiểm lệch thứ tự hơn lúc rời peer. Với cửa sổ 32 mặc định, SEC từ chối 1–3 % ESP của PC4 (lệch tối đa 23 khi rời PC4), và kernel nhận hơn 1000 gói/10 s. Với 128 thì kernel nhận 0 (ngày 2026-11-03). 128 là cửa sổ lớn nhất daemon giao (`sa.c`). Linux giữ cửa sổ lớn hơn 32 trong `XFRMA_REPLAY_ESN_VAL`, kể cả khi không có ESN; daemon đọc ở đó.
- **Chiều đi đã tăng tốc** (③): gói khớp entry "vào tunnel": lõi sửa (TTL−1, NAT nếu có), đặt header L2 ngoài, đưa ra `core_out.tun`; `ipsec_tunnel` mã bằng SA ra hiện tại của tunnel (SA ra mới nhất engine giữ, như kernel), ra dây cổng đó. Gói trong dài hơn MTU của tunnel lên kernel nguyên vẹn (kernel trả ICMP hay mã rồi phân mảnh). MTU như `xfrm_state_mtu()` của Linux: `((MTU cổng − PPPoE − header ngoài [+ UDP] − 8 − IV − ICV) & ~(khối − 1)) − 2`, khối 16 với CBC, 4 với GCM: 1422 với `aes256-sha256` ESP trong UDP trên cổng 1500. Tunnel không còn SA ra nào thì gói bị bỏ, và kết nối của tunnel được rút (`core_flush_tunnel`).
- **Một tunnel, một worker** (ticket `16`): mọi gói vào một tunnel do một worker mã, để ESP ra cáp đúng thứ tự số. Mã trên 4 worker thì PC3 thấy gói lệch tới 38, quá cửa sổ replay 32 của strongSwan, và `XfrmInStateSeqError` tăng. Worker của tunnel là worker nhận ESP kernel gửi trên tunnel đó (RSS luôn đưa luồng đó về một worker; mảnh ghép lại thì không tính). Worker khác chuyển gói vào tunnel qua ring của worker đó (`AWAY_RING` = 1024). Ở chế độ `--event`, mỗi lần chuyển còn kèm một event để đánh thức nó; `event_dpaa2` cấp phát mỗi event (`rte_malloc`), nên chỉ một event cho mỗi lần chuyển. Gửi event tới hàng đợi mà cổng không link cần patch 005 của gói `dpdk`. Một tunnel vì thế chỉ chạy tới sức một worker.
- **Tunnel mất SA ra hiện tại** (`sa-stop`, `sa-del`): SA ra mới nhất còn lại thay; không còn thì kết nối và bản học của tunnel bị rút, gói đi kernel. Tunnel mất SA cuối thì cũng vậy, và số tunnel chỉ được dùng lại sau một lần chờ RCU. Từng kết nối rút kiểu này có một dòng `conn` trong trả lời (ticket `17`): daemon chờ giao lại nó như kết nối mới.
- **Rekey** (ticket `17`, Q9): strongSwan cài SA mới cùng `reqid`. Trước khi daemon giao, ESP trên SPI mới đi qua engine nguyên vẹn (kernel tự đánh số SA ra mới, kernel tự giải SA vào mới). Giao xong, SA ra mới là SA ra mới nhất của tunnel: gói ③ của mọi kết nối của tunnel ra trên nó, đánh số từ số đầu của nó; gói ④ trên SA vào mới khớp đúng entry, vì entry gắn với tunnel chứ không với SPI. SA cũ bị xoá thì engine bỏ nó, không rút gì. Daemon giao SA mới ngay khi có sự kiện `NEWSA`, trước khi strongSwan xoá SA cũ, nên tunnel không lúc nào thiếu SA ra (seam 3 kiểm với rekey thật giữa hai strongSwan).
- **Giới hạn số thứ tự** (Q12): engine không đánh số nào quá `IPSEC_SEQ_MAX` = `2^32 − 2^26`. Mỗi job mã của SA ra lấy một số (đếm atomic trong bản ghi của SA, một cache line riêng); hết số thì gói bị bỏ và đếm (`dropped`), cả gói ③ lẫn ESP kernel gửi ra, và `seq` của `sa` dừng ở `IPSEC_SEQ_MAX`. SA ra có số đầu quá `IPSEC_SEQ_MAX` bị từ chối (`err unsupported`). Daemon trả SA về kernel trước đó (mục Daemon đồng bộ): việc bỏ gói chỉ xảy ra khi daemon trễ.
- **ESP kernel gửi ra** (từ phía kernel của một cổng, trước khi lõi thấy gói): ESP thường hay ESP trong UDP, tới đúng đích, SPI, nguồn và cổng UDP của một SA ra engine giữ: header L2 kernel gửi được giữ trong vùng riêng của mbuf (`IPSEC_PRIV_SIZE`), SEC giải lại, rồi mã lại với số của engine, gói ra phía dây của cùng cổng với header L2 đó (VLAN, PPPoE với độ dài mới). Giải lại hỏng thì bỏ gói và đếm (`failed`): không gói nào mang số của kernel ra dây.
- **Đi ra nguyên vẹn:** ESP của SPI engine không giữ, từ địa chỉ hay cổng khác của SA, IKE (UDP có non-ESP marker, UDP 500), keepalive NAT-T, mọi gói khác. Không giữ SA ra nào thì worker không nhìn gói kernel gửi.
- **ESP kernel phân mảnh ra** (gói lớn không DF): phân mảnh giữa hai địa chỉ của một SA ra được ghép (`rte_ip_frag`, một bảng chung có khoá, chờ tối đa 500 ms; mảnh của một datagram có thể về các worker khác nhau), chép vào một segment (dài hơn một mbuf 2 kB thì vào pool riêng `ipsec_whole`: 128 mbuf một segment 64 kB; hết mbuf thì bỏ, đếm `dropped`), rồi đi như ESP không phân mảnh; ra dây thì phân mảnh lại theo MTU của cổng (PPPoE bớt 8) như Linux, với IP id kernel đã cho gói (header ngoài của SEC luôn có id 0: mảnh của hai gói sẽ bị ghép lẫn). Frame nhiều segment được chép thành một segment. Datagram ghép xong mà không phải ESP của SA giữ (IKE lớn) được phân mảnh lại và ra nguyên nội dung.
- **Rút có trật tự**, hai bước như spec (engine báo số cuối, daemon ghi vào kernel, rồi ESP kernel ra nguyên vẹn): `sa-stop`: engine ngừng dùng SA, chờ worker qua RCU (bảng đọc không khóa), báo `seq` cuối = số đầu − 1 + số job SA mã đã nhận (`taken` của "ESP ops", tính cả job còn trong SEC hay chờ credit); từ đó ESP kernel trên SPI đó bị bỏ (đếm `dropped`). `sa-del`: SA ra khỏi bảng, ESP kernel trên SPI đó ra nguyên vẹn. `sa-del` một mình (SA kernel đã xoá), `sa-flush` và phiên daemon đóng làm cả hai bước. Session đi khi hết job (`ipsec_poll`), id được dùng lại sau một lần chờ RCU nữa.
- **Bộ đếm:** `bytes`/`packets` của `sa` là gói ③④ engine tự mã/giải (độ dài gói trong); gói ①② kernel tự đếm. Daemon cộng phần tăng vào SA của kernel mỗi 5 s. `failed`, `dropped`: job SEC báo lỗi, gói mất trên đường (credit, hết mbuf).
- **Giới hạn số tunnel** (Q16): tối đa `--tunnels` tunnel (4096); SA của tunnel thứ 4097 bị từ chối (`err full`), daemon cũng không giao (`--tunnels` của daemon). ESP của nó đi qua engine nguyên vẹn. Tunnel mất hết SA thì để chỗ cho tunnel khác.
- **Đường tới peer đổi** (ticket `18`, Q14): `flush-route MẠNG/LEN` rút cả kết nối của mọi tunnel có peer (đích của SA ra, nguồn của SA vào) trong mạng đó, cùng bản học của tunnel (header L2 ngoài): `ipsec_flush_peer()`. Route tới mạng trong (10.20.0.0/24) rút như mọi kết nối; `flush-mac` (gateway tới peer đổi MAC) và `flush-port` (cáp của WAN) đã rút được kết nối tunnel vì entry và bản học giữ header L2 ngoài và cổng ra. SA vẫn ở engine: ESP kernel vẫn được đánh số lại, kết nối học lại ở gói kế tiếp.
- **Bộ nhớ:** bảng SA, tunnel và bộ đếm của 24576 SA khoảng 4 MB; mbuf thêm `worker × (ESP_WAIT_MAX + 256) + 1024` cho gói SEC và credit đang giữ; pool `ipsec_whole` 10 MB (5 trang 2 MB, đo trên mạch). `layout hugepages()` cộng các phần này.

## Daemon đồng bộ

`bmchwaccel-syncd [--socket PATH] [--keepalive GIÂY] [--tunnels N] [--kept FILE] [--pppoe FILE] [--verbose]` (spec: Daemon đồng bộ; Q7).

- **Nguồn:** sự kiện NEW/UPDATE/DESTROY của ctnetlink (bộ đệm nhận 8 MB), dump conntrack khi vừa giữ được engine.
- **Điều kiện giao** (`sync.c`): IPv4 TCP/UDP, ASSURED, connmark không có `0x10000`, không có helper, không phải kết nối do helper chờ (dữ liệu FTP, media SIP), TCP thì ở ESTABLISHED. Engine đã học đủ hai chiều hay chưa là việc của engine: `err unlearned` (hay `err full`) thì thử lại sau 1 s, 2 s, 4 s… tối đa 30 s, tới khi được hay kết nối không còn đủ điều kiện. Kết nối có một đầu ở cổng 1G vì thế không bao giờ được giao, chỉ được thử lại mỗi 30 s.
- Sự kiện UPDATE chỉ có trạng thái TCP khi trạng thái đổi. Kết nối chưa biết mà sự kiện không có trạng thái (ví dụ `conntrack -U --mark 0/0x10000`) thì daemon hỏi conntrack.
- **Rút** khi: DESTROY; TCP rời ESTABLISHED (FIN, RST lên kernel); connmark có thêm `0x10000`.
- **BE_LIBERAL:** giao xong một kết nối TCP thì đặt cờ này cho cả hai chiều trong conntrack: kernel không thấy cửa sổ TCP đi tiếp trong lúc engine chuyển, FIN/RST về sau không bị coi là INVALID.
- **Giữ conntrack sống:** mỗi `--keepalive` giây (mặc định 10) daemon hỏi `active` các kết nối có gói từ lần trước, đặt timeout của chúng trong conntrack bằng timeout của loại đó (`nf_conntrack_tcp_timeout_established`, `nf_conntrack_udp_timeout_stream`) trừ thời gian từ gói cuối. Kết nối im lặng thì hết hạn đúng như khi không có engine, và sự kiện DESTROY rút nó. Kết nối engine giữ mà daemon không biết, hoặc conntrack không còn, bị rút.
- **Giữ engine:** `claim`, rồi `flush` (bỏ cả kết nối một phiên khác đã giao), dump và giao lại.
- **Engine đi mất** (chết, khởi động lại): daemon chờ, mỗi giây thử nối lại, rồi giữ engine như trên. Kernel làm mất sự kiện (ENOBUFS): `flush` rồi giao lại từ đầu.
- **Khi routing đổi** (`watch.c`, spec: rút kết nối khi route, rule hay neigh đổi; link của cổng xuống). Engine chuyển một kết nối theo đường kernel đã gửi lúc giao. Daemon nghe rtnetlink (link, neighbour, nexthop, địa chỉ, route và rule IPv4; bộ đệm 1 MB), đọc sẵn interface và neighbour lúc khởi động, và bắt engine rút:
  - route thêm, xóa, thay (mọi bảng, trừ route cache): `flush-route MẠNG/LEN`; route mặc định: `flush`;
  - rule hay nexthop object đổi, hay một địa chỉ IPv4 mất: `flush`. Route của FRR 10 dùng nexthop object: đổi nexthop tại chỗ thì route đi theo mà kernel không báo route nào; kernel cũng bỏ route của một địa chỉ mất mà không báo;
  - neighbour đổi MAC: `flush-mac MAC-CŨ`. Neighbour bị kernel xóa vẫn được nhớ, vì engine có thể vẫn gửi tới MAC đó (kernel không thấy gói của nó nữa); nhớ tối đa 65536 neighbour;
  - một interface xuống (admin down, mất carrier, bị xóa): `flush-port` nếu đó là cổng của engine (tên lấy từ lệnh `ports` lúc giữ engine), không làm gì nếu là cổng của một bridge (cổng 1G của `br-lan`), `flush` với interface khác (`br-lan`, `pppoe-wan`, VLAN): route của nó đi theo nó.
  - Mất sự kiện rtnetlink (ENOBUFS): `flush`, đọc lại interface và neighbour.
  - Nhiều thay đổi cần `flush` trong một lượt đọc thì chỉ `flush` một lần.
  - Kết nối bị rút được chờ giao lại như kết nối mới (`sync_unbound`): thử sau 1 s, rồi 2, 4… s tới khi engine học xong đường mới. Gói kế tiếp của nó đã đi qua kernel, theo đường mới.
  - Mỗi thay đổi routing có rút gì đó cũng đặt lại lần thử của các kết nối đang chờ về 1 s (`sync_retry_soon`): một kết nối không học được trong lúc đường sai (blackhole) được tăng tốc lại khoảng 1–2 s sau khi đường đúng lại, không phải chờ backoff đã giãn tới 8–16 s.
  - Đo trong QEMU: kernel xóa conntrack của kết nối MASQUERADE qua một interface bị `ip link set down` mà daemon không nhận sự kiện DESTROY. Interface đó xuống thì daemon đã rút (cổng của engine, hoặc `flush`); một kết nối engine còn chuyển mà conntrack không còn thì bị rút ở lượt giữ conntrack sống kế tiếp.
- **Log** (syslog qua procd): lúc giữ được engine (`claimed Tăng tốc phần cứng: N connections accelerated, M waiting for both directions`), lúc mất engine, lúc mất sự kiện, lúc routing đổi làm engine rút kết nối (`the route to 203.0.113.0/24 changed: 3 connections go through the kernel until they are accelerated again`, `eth0 went down: …`); `--verbose` thêm một dòng cho mỗi lần giao/rút và cho mỗi thay đổi routing không rút gì.
- **Tunnel IPsec** (ticket `15`, `sa.c`): nghe `NETLINK_XFRM` (`NEWSA`, `UPDSA`, `DELSA`, `FLUSHSA`, `EXPIRE`), dump SA lúc giữ được engine (trước kết nối), sau `sa-flush`.
  - **Điều kiện giao:** ESP, IPv4, tunnel mode, không ESN, không offload, không nén; ESP thường hay trong UDP (`UDP_ENCAP_ESPINUDP`); AES-CBC 128/256 + HMAC-SHA1-96/256-128/384-192/512-256, hay AES-GCM 128/256 ICV 16; SA của một địa chỉ của router (nguồn: ra, đích: vào); đường tới peer ra một cổng của engine, một VLAN trên nó, hay một session PPPoE trên một trong hai (`RTM_GETROUTE`, rồi thiết bị dưới session PPPoE theo cột 4 và 3 của `/proc/net/pppoe`, rồi `/sys/class/net/IF/lower_*`, tối đa 8 thiết bị); không thiết bị nào trên đường đó bị Feature khác giữ trên CPU (Q15: `/var/run/bmcHwAccel/on_cpu` của `bmchwaccel keep`, ví dụ bmcqos shape `wan`; log `stays on the kernel: its WAN is kept on the CPU`); SA vào có cửa sổ ≤ 128; SA ra có `oseq + 2^24` dưới `SA_SEQ_LEAVE` (`2^32 − 2^26 − 2^22`, xem dưới); tunnel đã giữ, hay chưa đủ 4096 tunnel (`--tunnels N` để thử). `--verbose` ghi lý do mỗi SA ở lại kernel.
  - Đường được xét lúc giao (SA đã giữ thì không xét lại khi chỉ có dump). Routing đổi (một lần rút do `watch.c`, hay một địa chỉ mới) thì ở tick kế tiếp daemon dump lại SA: SA trước đó chưa có đường qua engine (link `eth0` vừa lên, route tới peer vừa có) được giao. SA đã giữ không bị rút khi đường đổi (Q14).
  - **`on_cpu` đổi:** `bmchwaccel keep`/`release` dừng rồi chạy lại daemon (`keep.sh`): lúc dừng SA được rút có trật tự (ghi `oseq`), lúc chạy lại SA của WAN bị giữ ở lại kernel; bỏ giữ thì được giao lại.
  - `--kept FILE`, `--pppoe FILE`: file thay cho `/var/run/bmcHwAccel/on_cpu` và `/proc/net/pppoe`, cho seam 3.
  - **Giao:** `sa-add` với số đầu = `oseq` hiện tại của kernel + `2^24`; ngay sau đó ghi `oseq` của kernel = số đó − 1 + `2^24`. Giao xong một SA ra thì các kết nối đang chờ được thử lại sau 1 s (`sync_retry_soon`): SA mới của một tunnel (rekey đến trễ) cho chúng học được.
  - **Mỗi 1 s:** `sa`, rồi `oseq` của mỗi SA ra = `seq` của engine + `2^24` (`XFRM_MSG_GETAE` rồi `NEWAE` có `NLM_F_ACK`; không bao giờ lùi). **Mỗi 5 s:** cộng phần tăng của `bytes`/`packets` vào lifetime của SA (`XFRMA_LTIME_VAL`, giữ `add_time`).
  - **Rút có trật tự** khi SA đổi mà không còn giao được (`UPDSA`, cổng NAT-T đổi), khi số của engine trên SA ra tới `SA_SEQ_LEAVE` (`2^32 − 2^26 − 2^22`: khoảng 4 s của SA nhanh nhất trước `IPSEC_SEQ_MAX` của engine, Q12; log `... goes through the kernel again: its sequence numbers near their end`) và khi daemon dừng: `sa-stop`, ghi `seq` cuối + `2^24` và bộ đếm cuối vào kernel (không ghi được thì log), rồi `sa-del`. Kernel đi tiếp từ đó, vẫn dưới `2^32`; strongSwan rekey theo giờ của nó. SA kernel xoá (`DELSA`, `FLUSHSA`, `EXPIRE` hard): chỉ `sa-del`.
  - **Kết nối tunnel rút:** dòng `conn` trong trả lời `sa-stop`/`sa-del` (tunnel không còn SA ra) được chờ giao lại như sau khi routing đổi (`sync_unbound`), log `Tunnel IPsec of ... : N connections go through the kernel until they are accelerated again`.
  - **Thứ tự lúc dừng** (SIGTERM): `flush` kết nối, rút SA có trật tự, rồi đóng phiên. Daemon chết thì engine rút hết khi phiên đóng; kernel đi tiếp từ lần ghi gần nhất (≤ 1 s), đã vượt mọi số engine cấp.
  - Mất sự kiện xfrm (ENOBUFS): dump lại, SA không còn trong kernel thì rút.
  - Log không dùng chữ "SA": `Tunnel IPsec of 192.168.2.1 (key 0xc0000001, out) is accelerated`, `... stays on the kernel: LÝ DO`, `... goes through the kernel again: LÝ DO`.
- **`bmcHwAccel` điều khiển daemon như `cmm`** (`engine-dpdk.sh`): init script của daemon bị tắt ở uci-defaults; `bmchwaccel apply` chạy nó khi bật, ở bố cục engine và khi engine trả lời (`supervise-engine` gọi `apply` khi engine vừa trả lời), dừng nó khi tắt. `status` báo `on` khi engine trả lời và daemon giữ phiên (`claimed`), `unavailable`/`daemon` khi engine trả lời mà không có daemon. Daemon chết thì `supervise` của `bmcHwAccel` chạy lại nó (tối đa 5 lần liên tiếp), engine đã rút hết kết nối từ lúc phiên đóng.

## Test

Mọi test chạy bằng một lệnh, trong container `ubuntu20`:

```sh
docker exec ubuntu20 sh /home/working/github/bmcfirewall_ls1046-ls1088-dpdk/package/bmc/bmcHwAccelDpdk/tests/run.sh
# chỉ seam 1, hoặc vài test của nó
docker exec ubuntu20 sh .../tests/run.sh unit [TEST...]
# chỉ seam 2, hoặc vài kịch bản
docker exec ubuntu20 sh .../tests/run.sh functional [masquerade port-forward kernel refused]
# engine từ chối tuỳ chọn sai (exit 1, kèm lý do)
docker exec ubuntu20 sh .../tests/run.sh args
```

- Lần đầu, `host-dpdk.sh` build DPDK của gói `dpdk` cho máy build (khoảng 80 s), vào `build_dir/host/bmcHwAccelDpdk-dpdk`. Cần `dl/dpdk-lf-6.12.49-2.2.0.tar.gz` và `dl/pyelftools-0.32.tar.gz` (`make package/network/utils/layerscape/dpdk/download`).
- Container là aarch64 (Mac arm64), không phải x86 như ticket ghi. DPDK chạy `--no-huge --no-shconf`: container không có hugepage.
- **Seam 1** (`tests/unit/core_test.c`): dựng gói như lúc vào từ cáp hoặc ra từ kernel, đưa qua `core_rx()` và các hàm điều khiển, rồi chỉ xem gói đi đâu, ra sao, và hàm trả lời gì. Gói mong đợi dựng từ đầu, checksum tính bằng `rte_ipv4_cksum()`/`rte_ipv4_udptcp_cksum()`. Có các test:
  - checksum incremental so với tính lại trên 2000 kết nối ngẫu nhiên;
  - UDP checksum bằng 0 ra 0xffff;
  - một worker và một luồng cập nhật cùng chạy 2 s;
  - VLAN và PPPoE (ticket `10`): bốn dạng header hai chiều, kèm checksum; checksum ngẫu nhiên trên 2000 kết nối có VLAN và PPPoE ngẫu nhiên; MTU khi ra PPPoE; headroom; padding; gói PPPoE và VLAN sai dạng; quay số lại;
  - rút theo mạng đích và theo MAC đích: đúng kết nối, quên đúng bản học.
- `tests/unit/ipsec_test.c` (Tunnel IPsec của engine, backend OpenSSL; ESP của kernel là pcap Linux của mạch tạo hay OpenSSL cùng khoá, số 1; peer là một SA vào cùng khoá): ESP kernel trên SA giữ ra với số của engine, cùng header L2, peer đọc ra đúng gói (6 thuật toán); số của engine liên tiếp; gói không thuộc SA giữ (SPI khác, nguồn khác, ESP thường trên SA trong UDP, từ dây, IKE, keepalive) ra nguyên; giải lại hỏng thì bỏ và đếm; VLAN, PPPoE (độ dài mới); ESP phân mảnh (mảnh cuối tới trước) được ghép, đánh số, phân mảnh lại theo MTU, cả PPPoE; datagram phân mảnh không phải ESP giữ thì ra nguyên nội dung; rút: `seq` cuối, ESP kernel ra nguyên, giữ lại từ số mới; rút khi SEC còn job; giới hạn tunnel; SA trùng, SA không làm được; `flush`.
- `tests/unit/sa_test.c`: điều kiện giao SA (từng điều kiện, cả WAN giữ trên CPU), thiết bị dưới session PPPoE đọc từ `/proc/net/pppoe`, WAN bị giữ theo `on_cpu`, dòng `sa-add`, bảng SA và tunnel, 24576 SA, `SA_SEQ_LEAVE`.
- `ipsec_test.c` (ticket `17`): rekey (SA mới đi kernel tới khi được giao, rồi kết nối ra trên SA ra mới và vào trên SA vào mới mà không bị rút; SA cũ xoá không rút gì); kết nối tunnel rút được báo (`sa-stop` SA ra duy nhất, `sa-flush`); không số nào quá `IPSEC_SEQ_MAX` (gói ③ và ESP kernel bỏ và đếm); SA ra không còn số bị từ chối.
- `tests/unit/esp_test.c` (seam "ESP ops", backend OpenSSL giữ kết quả lại tới khi test cho về, như SEC làm xong từng job của queue pair theo thứ tự): mọi thuật toán, ESP thường và trong UDP, mã rồi giải lại; header ngoài; ESP do kernel Linux của mạch tạo (`tests/esp/linux/`) giải được; out-of-place; ESP bị sửa thì hỏng và được đếm; chống replay; một SA bận không làm SA khác cùng queue pair chờ sau nó (1400, 512, 64 B); thứ tự job của một SA; job vượt credit và hàng chờ bị bỏ và đếm, mbuf trả hết; lane khác vào queue pair khác; SA không tồn tại; thêm/xoá SA.
- `tests/esp/linux-esp.sh`: chạy trên mạch, tạo lại `tests/esp/linux/*.pcap` (hai namespace và một cặp veth, không đụng gì ngoài chúng).
- Engine của seam 2 và `ctl` link backend OpenSSL: tự kiểm ESP chạy ở chế độ poll; `run.sh ctl` kiểm lệnh `esp`.
- `tests/unit/sync_test.c`, `tests/unit/watch_test.c`: phần quyết định của daemon, không DPDK, không thư viện conntrack: điều kiện giao, thử lại, giao lại kết nối engine đã rút; route, rule, địa chỉ, neighbour, interface nào bắt engine rút gì.
- **Seam 2** (`tests/functional/`):
  - `bmchwaccel-engine` thật, cổng là `net_memif` (engine làm server);
  - `feeder.c` làm client: chạy kịch bản, gửi pcap vào từng phía, chờ engine xử lý xong (so bộ đếm `stats`), gửi lệnh điều khiển;
  - `scenario.py` dựng gói vào và gói mong đợi từ đầu bằng Python (checksum tự tính);
  - `run.sh` so pcap ra với pcap mong đợi (`pcapcmp.py`) và bản chép lệnh điều khiển (`diff`).
  - Kịch bản: `masquerade` (TCP và UDP, có checksum 0), `port-forward`, `kernel` (các gói luôn lên kernel), `refused` (cổng 1G, lệnh sai), `ports` (link, tốc độ và bộ đếm phía dây; `net_memif` báo 100000 Mb/s).
  - Kịch bản `daemon`: phiên `claim`, `active`, phiên đóng thì engine rút hết; phiên không `claim` đóng thì không.
  - Kịch bản `reroute`: `flush-route`, `flush-mac` rút đúng kết nối, liệt kê nó, gói kế tiếp lên kernel; lệnh sai.
  - Kịch bản `vlan-pppoe`: VLAN 30 ra WAN thường, LAN thường ra PPPoE, VLAN ra PPPoE, PPPoE trên VLAN 35 của WAN: gói ra mang header kernel gửi, độ dài PPPoE đúng, không padding; 1452 byte dữ liệu TCP (IPv4 1492) ra PPPoE được, 1453 lên kernel; VLAN khác, session khác lên kernel.
  - Kịch bản `pppoe-redial`: `flush` như daemon làm khi `pppoe-wan` mất; gói của session cũ lên kernel; kết nối học lại trong session mới được tăng tốc với header của session mới.
  - Kịch bản `ipsec`: `sa-add` (trùng, sai, không làm được), `sa`; ESP kernel gửi ra với số của engine (ESP mong đợi dựng bằng Python: `openssl enc` cho AES-CBC, `hmac` cho SHA-256); IKE, keepalive, SPI khác, địa chỉ khác, UDP thường ra nguyên; ESP phân mảnh ghép, đánh số, phân mảnh lại; `sa-del` báo `seq` cuối, sau đó ESP kernel ra nguyên; phiên daemon đóng thì rút hết SA.
  - Kịch bản `ipsec-accel` (ticket `16`): kết nối TCP qua tunnel; bắt tay qua kernel (ESP kernel đánh số lại, ESP của peer lên kernel nguyên vẹn), `bind`, rồi ③ PC1 → ESP do engine mã với số kế tiếp, ④ ESP của peer → gói tới PC1 TTL−1; `sa` đếm byte/gói ③④, `list`; cùng tuple từ tunnel khác, FIN, gói không thuộc kết nối: ESP gốc lên kernel; gói trong 1423 byte (MTU tunnel 1422) lên kernel; `sa-stop` SA ra duy nhất thì kết nối được rút và có dòng `conn` của nó.
  - Kịch bản `ipsec-rekey` (ticket `17`): rekey khi kết nối đang được tăng tốc: ESP trên SPI mới trước khi giao đi nguyên vẹn; giao xong, ③ ra trên SA ra mới từ số đầu của nó, ④ vào trên SA vào mới (và SA vào cũ); xoá SA cũ không rút gì; xoá SA ra cuối thì rút và báo kết nối.
  - Kịch bản `ipsec-reroute` (ticket `18`): kết nối qua tunnel được tăng tốc; `flush-route` không phải của peer hay mạng trong: không rút; `flush-route` tới peer (/32, /24), tới mạng trong, `flush-mac` gateway, `flush-port eth0`: rút và liệt kê kết nối, gói kế tiếp lên kernel, ESP kernel vẫn được đánh số lại, kết nối học và `bind` lại được; SA vẫn ở engine.
  - Kịch bản `ipsec-limit`: SA ra bắt đầu ở `IPSEC_SEQ_MAX − 1`: hai ESP kernel ra với hai số cuối, cái thứ ba bị bỏ và đếm; số đầu quá giới hạn bị từ chối; xoá rồi thì ESP kernel ra nguyên vẹn.
  - Kịch bản `ipsec-tunnels` (engine chạy `--tunnels 2`, file `engine-args` của kịch bản): SA của tunnel thứ 3 bị từ chối, ESP của nó ra nguyên vẹn; tunnel 2 mất hết SA thì tunnel 3 vào được.
- Kết quả để ở `tests/out/functional/NAME/`: `in/`, `expect/`, `got/`, log của engine và feeder. Xem bằng `tcpdump -nnvvXr tests/out/functional/masquerade/got/eth0-wire.pcap`.
- **Seam 3** (`tests/daemon/qemu-test.sh`, chạy riêng vì cần image đã build, khoảng 5 phút):
  - image của LS1088 boot trong QEMU `virt`; trong VM, namespace `router` route + NAT (iptables) từ `client` sang `server` với conntrack riêng, không phụ thuộc fw3 hay chế độ nac của image;
  - `bmchwaccel-syncd` thật chạy trong `router`, `tests/daemon/tool.c engine` đóng vai engine và ghi lại mọi yêu cầu;
  - kịch bản: `dump` (giao lúc khởi động; UDP không có chiều trả lời, helper FTP, `0x10000` thì không; BE_LIBERAL), `events` (kết nối mới, `0x10000` thêm/bớt, TCP đóng, DESTROY), `unlearned` (thử lại tới khi engine nhận), `keepalive` (timeout giữ từ gói cuối, kết nối im lặng hết hạn và bị rút, kết nối lạ bị rút), `restart` (engine khởi động lại được giữ và giao lại), `stop` (daemon dừng thì phiên đóng); `route` (route thêm/xóa: `flush-route`; route mặc định, rule, nexthop object, địa chỉ mất: `flush`; kết nối engine đã rút được giao lại), `neigh` (đổi MAC: `flush-mac` MAC cũ; cùng MAC: không; xóa rồi học lại MAC khác: `flush-mac`), `link` (cổng của engine xuống: `flush-port` một lần; cổng của bridge: không; interface khác: `flush`), `ipsec` (xfrm thật bằng `ip xfrm` trong `router`, daemon chạy `--tunnels 2`: SA ra và vào qua cổng của engine được giao với số đầu `oseq + 2^24` và kernel đi tiếp quá số đó ngay; mỗi điều kiện ở lại kernel; tunnel thứ 3; engine từ chối; `oseq` của kernel theo `seq` của engine mỗi giây; bộ đếm cộng phần tăng; SA vào kiểu strongSwan (`allocspi` rồi `update`); SA bị xoá, hết hạn hard; kết nối engine báo đã rút cùng SA thì được giao lại; engine khởi động lại: giao lại từ `oseq` mới; daemon dừng: `sa-del` có trật tự rồi mới đóng phiên, `oseq` = số cuối + `2^24`; SA ra mà số của engine tới `SA_SEQ_LEAVE` thì được rút có trật tự, `oseq` = số đó + `2^24`; `flush` của xfrm), `ipsec-way` (ticket `18`: SA qua VLAN trên cổng, qua session PPPoE trên cổng hay trên VLAN của nó được giao, qua session trên thiết bị khác thì không; `on_cpu` có cổng: SA của cổng, của VLAN và của PPPoE trên nó ở lại kernel, `on_cpu` đổi sang thiết bị khác và daemon chạy lại thì được giao; SA chưa có route ở lại kernel, route qua cổng tới thì được giao trong vài giây, route mất thì SA vẫn ở engine), `ipsec-rekey` (ticket `17`: strongSwan của image trong `router` và trong `client`, CHILD_SA 40 s rekey trước 20 s: SA mới cùng `reqid`, SPI khác, giao với số đầu `oseq + 2^24`, trước khi SA cũ bị `sa-del`). Engine giả giữ `eth6` của namespace `router` làm cổng.
  - `docker exec ubuntu20 sh .../tests/daemon/qemu-test.sh [KỊCH BẢN...]`
- **Vì sao `net_memif`, không phải `net_pcap`/`net_ring` như ticket ghi:**
  - kịch bản cần lệnh `bind` nằm giữa hai đợt gói;
  - `net_pcap` đọc hết file lúc khởi động; `net_ring` chỉ nạp được từ trong cùng tiến trình;
  - container không có hugepage (không chạy được hai tiến trình DPDK chung bộ nhớ) và không có quyền tạo interface.
  - `net_memif` nối hai tiến trình qua socket UNIX, chạy được với `--no-huge`. Feeder nhận một lần ngay khi nối, để vòng của engine có ô trống (chế độ copy).

## Bố cục engine lúc boot

ADR-0013; spec, mục Hai bố cục DPAA2. Không tạo hay xóa object DPAA2 nào lúc đang chạy: bố cục chỉ đổi qua một lần khởi động lại.

1. **`S11bmchwaccel-layout`** gọi `layout`, quyết bố cục của lần boot này và ghi vào `/var/run/bmchwaccel/layout`:
   - `bmchwaccel.global.enabled` là `0`: bố cục kernel;
   - có `/etc/bmcHwAccel/unavailable` (lý do của một lần boot hỏng trước đó) hoặc dấu boot `/etc/bmcHwAccel/booting` của hai lần boot liên tiếp trước đó: bố cục kernel. `bmchwaccel apply` lúc boot (`S54bmcHwAccel`) ghi syslog lý do (`engine` hay `boot_skipped`);
   - còn lại: cấp hugepage (`vm.nr_hugepages`, mount `hugetlbfs` ở `/dev/hugepages`), rồi thêm boot id của lần boot này vào dấu boot trước khi dựng bố cục engine. Kernel cho thiếu hugepage thì trả hết và boot ở bố cục kernel, lần sau thử lại; `layout skipped` nói lý do, `status` báo `unavailable`/`engine` cho riêng lần boot đó.
   - Init script chỉ làm việc này trong `boot()`, không trong `start()`: cài gói lúc đang chạy không cấp hugepage.
2. **`S90phy_init`** hỏi `layout`. Ở bố cục engine nó gọi `container build` cho các cổng của engine (`bmchwaccel.global.port`, mặc định `dpmac.1 dpmac.2`), rồi với mỗi cổng đó tạo `dpni.Z` trong `dprc.1` (`--fs-entries=1`, MAC của `dpmac`) và nối `dpni.Z` ↔ `dpni.Y`. Các `dpmac` khác như bố cục kernel. Cuối cùng `container check`; thiếu gì thì `layout fail`.
3. **`S91bmchwaccel-engine`** chạy `container check` (thiếu gì thì `layout fail --reboot`), rồi engine dưới `/usr/lib/bmcHwAccel/supervise-engine`, với `-l 0-W`, `--vdev=event_dpaa2`, `--event`. Số worker W là UCI ẩn `bmchwaccel.global.workers` (1–4, mặc định 4); worker ghim từ core 1. Log của engine vào syslog.

**Container** (`container build`, gọi `restool` trực tiếp):

- `dprc` con của `dprc.1`, nhãn `bmchwaccel`, gắn `vfio-fsl-mc`;
- mỗi cổng: `dpni.X` nối `dpmac`, `dpni.Y` (MAC `02:00:00:00:00:NN`); cả hai 1 TC, 8 hàng đợi, `--num-channels=4`, `--fs-entries=1`, `DPNI_OPTIONS` không có `SINGLE_SENDER` (bug MC 10.39.0, ticket `02`);
- 14 DPIO, 4 DPBP, 5 DPCON, 3 DPMCP, 4 DPCI: đủ cho 4 worker;
- một DPSECI: 8 queue pair (2 cho mỗi worker), `DPSECI_OPT_HAS_CG`, như `dynamic_dpl.sh`. Không tạo được thì container vẫn dựng, engine chạy không có ESP (IPsec đi kernel);
- ghi `/var/run/bmchwaccel/container`. `container check` kiểm lại từng object và đầu nối, in `port ethN dpni.X dpni.Y` cho engine, và `sec dpseci.N` khi có DPSECI.

**Khi hỏng** (ADR-0013, spec mục Gói `bmcHwAccel` trên LS1088):

- `layout fail [--reboot] LÝ DO` ghi `/etc/bmcHwAccel/unavailable` (giữ lý do đầu tiên của lần boot) và một dòng syslog `Tăng tốc phần cứng unavailable: LÝ DO; the next boot is without it`, trả hugepage về kernel; `--reboot` thì khởi động lại router. Lần boot sau ở bố cục kernel, `bmchwaccel status` báo `unavailable`/`engine`.
- `phy_init` không dựng được container: `layout fail` (không khởi động lại giữa lúc boot); `S91` thấy container không đủ thì `layout fail --reboot`. Container hỏng giữa chừng thì `dpmac` nó đã lấy vẫn có một cổng kernel không nối gì, để tên các cổng sau giữ nguyên (`wan` vẫn ở `eth0`).
- `supervise-engine` (của `bmcHwAccel`): engine chết thì chạy lại sau 1 s trên container cũ; chết lần thứ 3 trong 5 phút, hoặc không trả lời trên socket trong 60 s sau khi chạy, thì `layout fail --reboot`. Engine trả lời và chạy được 60 s thì `layout ok` xóa dấu boot. Trong lúc engine được chạy lại, `status` báo `unavailable`/`restarting`.
- Boot treo hay chết trước khi engine chạy ổn (kể cả mất điện hay khởi động lại bằng tay trong khoảng 1–2 phút đầu) để lại boot id của nó trong dấu. Một lần thì lần boot sau vẫn thử bố cục engine; hai lần liên tiếp thì các lần boot sau ở bố cục kernel, `unavailable`/`boot_skipped`. Một lần boot chạy ổn thì xóa dấu, đếm lại từ đầu.
- `bmchwaccel enable` (`layout retry`) xóa lý do và dấu của các lần boot trước. Sysupgrade cũng xóa (`/etc/bmcHwAccel` không được giữ).

Cổng và số worker là của lần boot (`layout ports`, `layout workers` đọc lại số đã lưu cùng bố cục), vì hugepage được cấp theo đó: đổi UCI có hiệu lực ở lần boot sau. `bmchwaccel get` báo giá trị không hợp lệ (có `field`); lần boot dùng mặc định.

**Giới hạn gửi của cổng** (ticket `21`): UCI `list tx_limit 'PORT:MBPS'` trong `bmchwaccel.global`, PORT là tên kernel của một cổng engine:

```sh
uci add_list bmchwaccel.global.tx_limit='eth0:980'
uci commit bmchwaccel
/etc/init.d/bmchwaccel-engine restart
```

- `S91bmchwaccel-engine` hỏi `layout tx-limits` với tên các cổng của engine, mỗi lần engine chạy (boot, hay engine chạy lại), và đưa vào engine thành `--tx-limit`.
- Mục sai bị bỏ qua, có một dòng syslog `tx_limit '...' left out: ...`, engine vẫn chạy. Mục sai là: cổng không phải của engine, tốc độ ngoài 8–10000, không có `:MBPS`, hoặc cổng có mục trước rồi.
- Mỗi lần engine chạy lại được tính là một lần dừng của `supervise-engine`: 3 lần trong 5 phút thì router khởi động lại ở bố cục kernel.
- Chưa có trên trang web hay `bmchwaccel get/set`. Bố cục kernel (dpaa2-eth) không có giới hạn này.

**Hugepage** (`layout hugepages`): mbuf của engine (2,5 kB mỗi cái, cho mọi hàng đợi và burst của worker) + 64 MB cho bảng kết nối và bản học + 64 MB cho EAL, eventdev và `dpdk-pdump` + ESP (32 MB + 2 MB mỗi worker, mục ESP). 2 cổng, 4 worker: 129 trang 2 MB (ticket `16`; 114 lúc đo ngày 2026-10-29 bên dưới). Đo trên mạch ngày 2026-10-21: engine dùng 84 trang (mbuf ~60 MB, bảng ~64 MB, EAL và eventdev ~44 MB). Ngày 2026-10-29, có ESP nhưng chưa SA nào: 93 trang dùng, 21 trống; 24576 SA thêm 20 MB (10 trang).

Thử trên máy build: `scripts/ls1088/tests/layout-test.sh` (`layout`), `scripts/ls1088/tests/phy-init-test.sh` (`phy_init` ở hai bố cục). Trên mạch: `scripts/ls1088/acceptance.sh` (`boot`, `idle`, `restart`, `carrier`, `pdump`).

## Thống kê và bắt gói

Ở bố cục engine, `eth0`/`eth1` của kernel là `dpni.Z`, nối với phía kernel của engine (`dpni.Y`). Vì vậy:

- `ip -s link`, `/proc/net/dev`, `ethtool -S`, `tcpdump -i eth0` chỉ thấy phần traffic đi qua kernel. Kết nối đã tăng tốc (từ ticket `08`) không có trong đó.
- `ethtool eth0` báo link của sợi nối ảo: carrier theo cáp (engine bật/tắt `dpni.Y` theo `dpni.X`), nhưng `Speed: Unknown!`.

Số trên dây lấy từ engine:

```sh
bmchwaccel ports
{"status":0,"message":"...","ports":[{"interface":"eth0","link":"up","speed":10000,"rx_bytes":…,"tx_bytes":…,"rx_packets":…,"tx_packets":…},…]}
```

- Mỗi cổng của engine: `link` (`up`/`down`) và `speed` (Mb/s, hoặc `"unknown"` khi không có link hay PMD không biết tốc độ) của `dpmac`, cùng byte/gói rx/tx của `dpni.X` (phía dây: mọi frame qua cáp, cả phần đi kernel lẫn phần engine tự chuyển). Lệnh `ports` của socket điều khiển, `rte_eth_link_get_nowait()` và `rte_eth_stats_get()` trên ethdev phía dây.
- Mảng rỗng ở bố cục kernel (bộ đếm của kernel đã đúng), trên LS1046, và khi engine không trả lời.
- `dpmac.1` và `dpmac.2` là link `FIXED`: MC báo tốc độ phía SFP+/XFI. Với module SFP+ 10G RJ45, `speed` là `10000` cả khi phía cáp đồng chạy 1G (như `ethtool eth0` ở bố cục kernel); tốc độ phía cáp đồng chỉ đọc được ở máy bên kia.
- Hai script của trang web (`get_net_stats.sh`, `get_ether_port_status.sh`) dùng lệnh này cho các cổng của engine (bmcwebUI, ticket `02` của `.scratch/hw-accel-ls1088/issues/`).
- Trên mạch: `scripts/ls1088/acceptance.sh wire-stats wire-stats-back carrier`.

Bắt gói trên dây (phía `dpni.X`) dùng `dpdk-pdump`. Trên mạch, khi engine đang chạy (`DPRC` là container của engine, từ `container check`):

```sh
DPRC=dprc.2 dpdk-pdump -l 6 -- --pdump "device_id=dpni.2,queue=*,rx-dev=/tmp/eth1.pcap,tx-dev=/tmp/eth1.pcap,total-num-mbufs=2047"
```

- `dpni.X` là phía dây, `dpni.Y` là phía kernel của cổng.
- `dpdk-pdump` là tiến trình phụ (secondary), dùng hugepage chung với engine (3 trang), nên chỉ chạy được khi engine chạy. Dừng bằng Ctrl-C.
- File pcap được ghi qua một cổng `net_pcap` mà cả engine (tiến trình chính) cũng phải tạo được, nên gói `dpdk` build cả driver `net/pcap`.
- Trên mạch EAL của nó mất khoảng 15 s mới chạy; gói trước lúc đó không có trong file.
- `dpdk-pdump` và `dpdk-proc-info` ở gói `dpdk`; testpmd và các ứng dụng test khác ở `dpdk-tools`, không có trong image release (`LS1088_RELEASE=1`), vì chúng có thể lấy cổng khỏi engine.

## Build cho mạch

`make package/bmc/bmcHwAccelDpdk/compile` (bật `CONFIG_PACKAGE_bmcHwAccelDpdk`, có sẵn trong `config_LS1088ARDB`). Gói `dpdk` stage header, thư viện tĩnh và `libdpdk.pc` (`Build/InstallDev`). `-mcpu=cortex-a53` đến từ `libdpdk.pc`. Engine cần `libpcap`, `libelf`, `libjansson`, `libbsd` và `restool` lúc chạy.

## Hiệu năng

Đo trên mạch ngày 2026-10-19 bằng `enginebench`, dùng lõi này (`--impl core`). Chi tiết: §9h mục 9 của `.scratch/hw-accel/ls1088-dpdk-duong-nhanh.md`.

- Phần việc của lõi trong bộ nhớ, 1 worker, bảng 256k: 397–401 chu kỳ/gói. Mốc của ticket là 370–400.
- Vòng đầy đủ, 4 worker eventdev parallel, bố cục spec (RSS), 4 channel, bảng 256k: 6,17 Mpps, tức 1037 chu kỳ/gói mỗi worker. Mục tiêu là ≤ 947 (6,76 Mpps): chưa đạt.

Bố cục engine trên mạch, ngày 2026-10-21 (ticket `04`, `scripts/ls1088/acceptance.sh`, log ở `logs/ls1088-t04/` của worktree), engine chưa tăng tốc kết nối nào:

- route + NAT `br-lan` → `wan`, iperf3 `-P 4`: 725 Mbps, chiều ngược 641 Mbps (bố cục kernel ở ticket `03`: 704 / 592). Vẫn một core của kernel bận ~99 % softirq.
- rảnh 60 s: mỗi core worker bận 0,4–0,7 %, luồng chính ~2 % (đọc link mỗi 100 ms).
- `kill -9` engine: procd chạy lại sau ~5 s trên container cũ, không object mới; ping qua `eth1` và tới PC2 mất 7,0 s.
- rút cáp `eth0`: `eth0` mất carrier, `wan` xuống; cắm lại thì lên lại, 15 s.
