# Bàn test của LS1088A-RDB cho `scripts/ls1088/acceptance.sh`

Script chạy trên PC1 và điều khiển board qua SSH. Nó lấy các hàm và các mục
không phụ thuộc board từ `scripts/hwaccel/acceptance.sh` (của LS1046A-RDB),
nên phần PC1, PC2 và cấu hình tạm của board giống
`scripts/hwaccel/bench.md`. File này chỉ ghi những gì khác trên LS1088.

Board có hai bố cục DPAA2, chọn lúc boot:

- **bố cục engine** (Tăng tốc phần cứng bật, mặc định của image đầy đủ):
  `dpmac.1` và `dpmac.2` thuộc `bmchwaccel-engine`; `eth0` và `eth1` là DPNI
  của kernel nối DPNI của engine, cùng tên và MAC như bố cục kernel;
- **bố cục kernel** (`uci set bmchwaccel.global.enabled=0`, hoặc lần boot
  trước không dựng được bố cục engine): mọi cổng là DPNI của `dpaa2-eth`, mọi
  gói đi qua Linux như firmware 24.10. Số đo ở bố cục này là mốc để so.

Ở bố cục engine, SSH từ PC1 đi qua engine (`eth1`): không dừng engine bằng
một lệnh SSH chạy trực tiếp, nếu không board mất đường vào tới khi khởi động
lại. Dừng hay chạy lại engine thì tách khỏi phiên SSH (`setsid`).

## Đấu dây

```
PC1 192.168.5.10 ── eth1 (10GBASE-T) [br-lan 192.168.5.1]  LS1088  [wan] eth0 (SFP+) ── module SFP+ 10G RJ45 ── PC2 192.168.2.10/24
```

| Cổng | MAC | Vai trò |
|---|---|---|
| `eth0` | `dpmac.1`, SFP+ | `wan` |
| `eth1` | `dpmac.2`, 10GBASE-T | `br-lan`, PC1 |
| `eth2`–`eth7` | `dpmac.3`–`8`, 1G | `br-lan` |
| `eth8` | `dpmac.9`, 1G | không dùng |
| — | `dpmac.10` | không có cổng |

Người dùng cắm cáp. `<nic>` dưới đây là card Ethernet của PC đang cắm vào
board.

## PC1

PC1 là 192.168.5.10/24, router 192.168.5.1, và phải gửi tới PC2 qua board:

```
route -n get 192.168.2.10 | grep gateway      # phải ra 192.168.5.1
sudo route -n delete 192.168.2.0/24; sudo route -n add 192.168.2.0/24 192.168.5.1
```

Board của dev image không có mật khẩu root, nên `ssh root@192.168.5.1` vào
thẳng.

## PC2

PC2 giữ 192.168.2.10/24 trên `<nic>`, không có gateway, và chạy hai iperf3
server:

```
iperf3 -s -D
iperf3 -s -p 5202 -D
```

PC2 là Mac thứ hai. Ngay cả khi cắm thẳng vào PC1, PC2 gửi sang PC1 chỉ
khoảng 780 Mbps, nên `baseline-back` thấp hơn `baseline` mà board không có
lỗi gì.

Card Ethernet USB của PC2 phải chạy ở USB 3. Ở USB 2.0 nó chỉ nhận khoảng
325 Mbps và gửi pause frame liên tục, và mọi số đo tụt theo:

```
system_profiler SPUSBDataType | grep -B2 -A8 -i realtek | grep Speed   # phải là Up to 5 Gb/s
```

Ra `Up to 480 Mb/s` thì rút card ra, cắm thẳng vào cổng USB-C của Mac (không
qua hub) rồi kiểm lại.

## Nạp image

Image là `bin/targets/layerscape/armv8_64b-glibc/openwrt-layerscape-armv8_64b-fsl_ls1088a-rdb-sdboot-squashfs-sysupgrade.bin`.
Image từ ticket 03 có phiên bản image 3.0; thẻ ghi trước đó (image tối thiểu
của ticket 01, 02) ở 2.0 và sẽ từ chối nó. Trên một thẻ dev như vậy, nâng
phiên bản của board trước rồi cài, không giữ cấu hình:

```
F=bin/targets/layerscape/armv8_64b-glibc/openwrt-layerscape-armv8_64b-fsl_ls1088a-rdb-sdboot-squashfs-sysupgrade.bin
ssh root@192.168.5.1 'cat > /tmp/fw.bin' < $F
ssh root@192.168.5.1 'uci set system.@system[0].compat_version=3.0; uci commit system; sysupgrade -T /tmp/fw.bin && sysupgrade -n /tmp/fw.bin'
```

Board lên lại sau khoảng 2–3 phút. Host key của dropbear đổi sau
`sysupgrade -n`.

## Chạy

```
sh scripts/ls1088/acceptance.sh                  # boot firewall ports wan-link baseline baseline-back
```

Board mới ghi khởi động ở security mode `nac`; script chuyển sang `off` trong
lúc chạy và trả lại khi kết thúc, như trên LS1046. `wan` không có DHCP thì
được đặt 192.168.2.1/24 trong lúc chạy.

Ở `nac` mà `wan` không có địa chỉ thì portal (chilli) không chạy và board bỏ
mọi gói từ `br-lan`, kể cả SSH của PC1: sau khi script trả lại `nac`, PC1
không vào được board nữa. Trên bàn test, để board ở `off`.

Các mục chỉ chạy khi gọi tên, ở bố cục engine:

```
sh scripts/ls1088/acceptance.sh idle restart pdump   # không cần người
sh scripts/ls1088/acceptance.sh wire-stats wire-stats-back   # không cần người; PC2 chạy iperf3 -s
sh scripts/ls1088/acceptance.sh webui-ports webui-ports-back # như trên, đọc số trang web hiện
sh scripts/ls1088/acceptance.sh carrier               # người rút rồi cắm lại cáp eth0
sh scripts/ls1088/acceptance.sh onoff enable-boot deaths   # không cần người; mạch tự khởi động lại 3 lần
```

- `idle`: 60 s không traffic, mỗi core worker của engine phải bận dưới 5 %.
- `restart`: `kill -9` engine trong lúc PC1 ping board và PC2 mỗi 0,1 s.
  `supervise-engine` của `bmcHwAccel` phải chạy lại engine trên container cũ,
  không object DPAA2 nào thêm hay mất; dòng kết quả có thời gian mất ping dài
  nhất. Mục này giết engine một lần: chạy nó trong 5 phút trước `deaths` thì
  lần giết thứ hai của `deaths` đã là lần thứ ba, mạch sang bố cục kernel và
  `deaths` FAIL. Giữa hai mục phải cách ít nhất 5 phút, hoặc có một lần khởi
  động lại.
- `onoff`: `bmchwaccel disable` trong lúc iperf3 `-P 4` chạy `ONOFF_TIME` giây
  (60) như `baseline`, rồi `enable`: `status` phải là `off` với
  `reboot_required` `true`, rồi `on`, mỗi lần một dòng syslog; iperf3 phải
  chạy hết, không giây nào dưới 1 Mbps (TCP không đứt). Lúc tắt, trong `WINDOW` giây `eth0` và `eth1` của kernel mỗi cổng
  thấy ít nhất `ENGINE_MIN` gói (10000): traffic về lại kernel. Bật lại được
  `WARMUP` giây (8) thì chấm như `accel`: kernel thấy ít hơn `KERNEL_MAX` gói,
  phía dây của `eth1` tăng.
- `enable-boot`: tắt rồi khởi động lại (bố cục kernel, `off`); `enable` ở đó:
  `off`, `reboot_required` `true`, `message` nói có hiệu lực sau khi khởi động
  lại, mạch không tự khởi động lại trong `ENABLE_WAIT` giây (30); khởi động
  lại: bố cục engine, `on`.
- `deaths`: giết engine 2 lần, mỗi lần phải `on` lại trong `DEATH_WAIT` giây
  (60); lần thứ 3 trong 5 phút thì mạch tự khởi động lại sang bố cục kernel,
  `unavailable`/`engine`, lý do giữ trong `/etc/bmcHwAccel`; `enable` rồi khởi
  động lại thì về bố cục engine, `on`.
- Mọi mục đọc trạng thái qua `bmchwaccel status`.
- `pdump`: `dpdk-pdump` bắt phía dây của `eth1` trong lúc board ping PC1: file
  phải có 5 gói hỏi và 5 gói trả lời.
- `wire-stats`: PC1 gửi PC2 như `baseline`, đọc `bmchwaccel ports` hai lần cách
  nhau `WINDOW` giây (10). `eth1` và `eth0` phải có, `link` `up`, `speed` là số;
  byte `eth1` nhận và `eth0` gửi trên dây phải tăng 85–125 % lượng iperf3 tải
  trong khoảng đó. `wire-stats-back`: chiều ngược lại (`-R`). `speed` của `eth0`
  là tốc độ MC báo cho `dpmac.1` (phía SFP+); phía cáp đồng xem trên PC2 (mục
  dưới).
- `carrier`: khi script in `unplug the cable of eth0`, rút cáp của `eth0` (chỉ
  cáp đó; đừng chạm cáp `eth1` của PC1), chờ khi script in `plug the cable of
  eth0 back`, rồi cắm lại. Mỗi bước chờ tối đa `CARRIER_WAIT` giây (60). Trong
  lúc chạy, script đặt `force_link 0` cho `wan` tĩnh của nó để `wan` xuống
  theo carrier như với DHCP. Ở bố cục engine, `link` của `eth0` trong
  `bmchwaccel ports` cũng phải thành `down` rồi `up`. Board có web UI thì
  `eth0` trong `get_ether_port_status.sh` (trang web) phải thành `inactive`
  rồi `active`.
- `webui-ports`: như `wire-stats`, nhưng đọc từ hai script trang web gọi:
  byte `eth1` nhận và `eth0` gửi trong `get_net_stats.sh` (dashboard) tăng
  85–125 % lượng iperf3 tải trong khoảng thời gian board đo giữa hai lần đọc
  (script chạy mất vài giây); `get_ether_port_status.sh` báo hai cổng
  `active` với tốc độ là số. `webui-ports-back`: chiều ngược lại. Cần gói
  bmcwebUI có ticket web LS1088 `02`.

## Module SFP+ 10G RJ45 (`wan-link`)

Mục này đạt khi `eth0` có link, và in ra tốc độ `ethtool` báo, link MC báo
cho `dpmac.1` và các sự kiện link gần nhất. `dpmac.1` là link `FIXED`: MC
báo link của phía SFP+ (XFI 10G), không phải của phía cáp đồng. Tốc độ thật
của phía cáp đồng phải đọc trên PC2:

```
ifconfig <nic> | grep media                       # PC2 macOS
```

Ghi lại cả hai con số. Thử module có tự hạ tốc độ không: đặt PC2 về
100 Mbps, xem board còn link không (`acceptance.sh wan-link`) và PC2 ghi
gì, rồi trả PC2 về tự động:

```
sudo ifconfig <nic> media 100baseTX mediaopt full-duplex
sudo ifconfig <nic> media autoselect
```

Rút cáp ở PC2 rồi chạy lại `wan-link`: nếu `eth0` vẫn có link thì module
không báo mất link phía cáp đồng cho board, và netifd, mwan3 không biết khi
WAN rớt cáp. Ghi lại điều đó.

### Giới hạn gửi của cổng (`tx-limit`, ticket `21`)

Module hạ 10G xuống 1G cho một PC 1G, nhưng không gửi PAUSE (`restool dpmac
info dpmac.1`: `rx pause: 0`). Engine cho mỗi worker một hàng đợi TX, nên khi
có nhiều luồng thì chùm khung ra ở 10G, và module làm hỏng khung: PC 1G thấy
`rx_crc_errors` (`ethtool -S`) với `iperf3 -P 4`, kể cả khi tắt tăng tốc.
Ngày 2026-11-03, với PC4 (I219-V) cắm thẳng vào module: 0,3–0,4 % khung lỗi,
nối thẳng `-P 4` chỉ được 821–842 Mbps. Bench có PC 1G sau module thì đặt:

```
uci add_list bmchwaccel.global.tx_limit='eth0:980'; uci commit bmchwaccel
/etc/init.d/bmchwaccel-engine restart        # trong setsid khi chạy qua SSH
logread | grep 'sends at most'               # eth0 sends at most 976 Mbps (4 channels; 980 asked, in steps of 8)
```

Mục `tx-limit` (chạy khi engine đã chạy được ít nhất 5 phút, mất khoảng 6
phút; engine chạy lại 3 lần, có chờ để không quá 2 lần trong 5 phút):

```
SERVER=192.168.2.1 PEER_SSH=raymond@192.168.2.1 PEER_KEY=$HOME/.ssh/id_ed25519_nhatgithub_cowork \
	IPERF3=iperf3-darwin sh scripts/ls1088/acceptance.sh tx-limit
```

- `TX_TEST_MBPS` (300): engine log đúng mức (theo bước 8 Mbps), một luồng tới
  `SERVER` được 85–105 % mức đó;
- không giới hạn: một luồng ≥ `TX_MIN` (900);
- `TX_LIMIT_MBPS` (980): `-P 4` ≥ `TX_MIN`, và với `PEER_SSH` thì peer không
  có khung lỗi CRC nào.
- Xong thì UCI trở lại như trước. Engine giữ mức `TX_LIMIT_MBPS` tới lần chạy
  lại sau.

## Mốc iperf3 của bố cục kernel (`baseline`, `baseline-back`)

PC1 gửi tới PC2 qua `br-lan` → `wan`, được route và masquerade, iperf3
`-P 4` trong 30 giây; `baseline-back` là chiều ngược lại (`-R`). Dòng kết
quả có:

- Mbps, giây chậm nhất và số lần truyền lại của iperf3;
- số gói `eth0` nhận và gửi trong 10 giây giữa lần chạy;
- tải của từng CPU trong 10 giây đó: phần trăm bận và phần trăm softirq;
- số kết nối tới PC2 được board masquerade.

Mbps và tải CPU không được chấm: đó là mốc. Mục đạt khi iperf3 có kết quả
và board masquerade các kết nối tới PC2. Ghi các dòng kết quả vào ticket.

## Một giờ traffic (`soak`)

PC1 phải thức suốt một giờ:

```
mkdir -p logs
caffeinate -i sh scripts/ls1088/acceptance.sh boot soak 2>&1 | tee logs/ls1088-soak.log
```

Một lần iperf3 3600 giây như `baseline`, đọc tải board 5 phút một lần. Mục
đạt khi board vẫn ở cùng lần boot, không phút nào dưới 1 Mbps, và kernel log
không có dòng báo sự cố nào từ lúc bắt đầu: `BUG:`, `Oops`, `WARNING:`, call
trace, hết bộ nhớ, stall, hoặc một dòng của MC, QBMan, driver DPAA2 có chữ
lỗi, hay một frame "without context". Mục in Mbps từng phút, CPU bận nhất
trong các lần đọc và bộ nhớ còn trống ở hai đầu.

Ở bố cục engine, engine lúc bắt đầu phải vẫn chạy lúc kết thúc (cùng PID,
không phải engine `supervise-engine` chạy lại), và `status` `on` lúc đầu thì
lúc cuối cũng `on`.

Thử ngắn: `SOAK=300 SOAK_EVERY=60 sh scripts/ls1088/acceptance.sh soak`.

## Năm lần boot liên tiếp (`reboots`)

```
caffeinate -i sh scripts/ls1088/acceptance.sh reboots 2>&1 | tee logs/ls1088-reboots.log
```

Mỗi lần boot phải qua những gì `boot` kiểm (kernel, MC 10.39.0, `phy_init`
đã chạy, `eth0`–`eth8` đúng `dpmac.1`–`9` với 1 entry flow steering và MAC
của dpmac, `dpmac.10` không có cổng, không có hugepage, không dòng kernel nào
báo sự cố) và mang được traffic của `baseline`. Mbps in ra, không chấm.
`REBOOTS=20` cho lần nghiệm thu Mốc A. Mỗi lần boot phải ở bố cục của lần boot
lúc bắt đầu: bắt đầu ở bố cục engine mà một lần boot rơi về bố cục kernel thì
FAIL, kèm `state` và `reason` của `bmchwaccel status`. Dòng của từng lần boot
in bố cục và trạng thái.

Ở bố cục engine, trước mỗi lần khởi động lại script chờ dấu boot
(`/etc/bmcHwAccel/booting`) mất, tối đa `MARK_WAIT` giây (180). Dấu mất khi
engine đã trả lời và chạy được 60 s. Hai lần khởi động lại liên tiếp trước
lúc đó thì các lần boot sau ở bố cục kernel (`boot_skipped`), như khi mạch
treo lúc boot, tới khi `bmchwaccel enable`.

Sau lỗi QBMan hay MC, chỉ dùng `reboot` thường, không dùng `reboot -f`.

## Các mục của LS1046 (`firewall`, `features`, `features-in`, `webui`)

Giống `scripts/hwaccel/bench.md`. Board không có `bmchwaccel` thì được test
như firmware 24.10. `features` cần macfilter và ddos_protect đang tắt trên
board.

```
sh scripts/ls1088/acceptance.sh features
```

`portal` và `proxy` chưa có ở đây: hai mục đó cần `bmchwaccel status` là
`on`, mà LS1088 chưa có `bmcHwAccel`.

## Sysupgrade (`sysupgrade`, `sysupgrade-old`)

`sysupgrade` cài `FIRMWARE` (mặc định là image ở trên) giữ cấu hình, chờ
board lên lại và kiểm cấu hình còn nguyên, kernel và root filesystem trên thẻ
là của image. Để nâng cấp sang một bản build khác, build thêm một lần sau một
commit rồi chạy mục với image đó.

`sysupgrade-old` dành cho board chạy firmware 24.10 của LS1088: `sysupgrade
-T` phải từ chối image vì phiên bản image (2.0 → 3.0), với thông báo bảo ghi
cả thẻ SD. Cách làm như `scripts/hwaccel/bench.md`: ghi thẻ 24.10, đưa key
SSH của PC1 cho board một lần, rồi
`BOARD=<địa chỉ của board> sh scripts/ls1088/acceptance.sh sysupgrade-old`.
`scripts/ls1088/build.sh test` hỏi cùng câu đó với một bản sao root
filesystem của 24.10, không cần board.

## Đường tăng tốc (`accel`, `accel-back`, `accel-udp`, `accel-udp-back`, `udp-oneway`, `keep-mark`, `daemon-kill`, `daemon-block`)

Cần bố cục engine, `bmchwaccel status` là `on` (daemon `bmchwaccel-syncd`
đang giữ engine), PC2 chạy `iperf3 -s`. Mỗi mục đọc bộ đếm kernel của
`eth0`/`eth1` (`/sys/class/net`) và bộ đếm phía dây của engine
(`bmchwaccel ports`) hai lần, cách nhau `WINDOW` giây.

```
IPERF3=iperf3-darwin sh scripts/ls1088/acceptance.sh accel accel-back accel-udp accel-udp-back udp-oneway keep-mark daemon-kill daemon-block idle
```

- `accel`, `accel-back`: so với mốc của bố cục kernel trên cùng bàn
  (`BASE_MBPS`, `BASE_BACK_MBPS`, mặc định 704 và 592 của ticket `03`).
- `daemon-block` chặn MAC của PC1 bằng macfilter khoảng `WINDOW` giây, rồi
  tắt macfilter như trước. macfilter chỉ ở chain `FORWARD`, nên SSH của PC1
  tới board không đứt.
- `accel-1g` cần PC1 cắm vào `eth3` (`ONEG_PORT`) trước khi chạy; script kiểm
  cổng của PC1 trong bảng MAC của `br-lan`. Lúc đó SSH tới board vẫn qua
  `br-lan`.

Ba mục dài chỉ chạy khi gọi tên, mỗi mục khoảng `LONG` giây (600):

```
IPERF3=iperf3-darwin sh scripts/ls1088/acceptance.sh udp-long udp-expire tcp-long
```

- `udp-expire` chờ timeout UDP của conntrack (180 s) cộng thời gian GC của
  conntrack, nên mất 3–5 phút.
- Không sửa `acceptance.sh` trong lúc nó chạy: shell đọc phần cuối của file
  sau, sửa giữa chừng làm hỏng dòng `RESULT`.

## VLAN và PPPoE (`accel-vlan`, `accel-pppoe`, `accel-vlan-pppoe`, các bản `-back`, `accel-redial`)

Ticket `10`. Cần bố cục engine với engine của ticket này, `bmchwaccel status`
là `on`. Tiêu chí như `accel`: so với `BASE_MBPS`/`BASE_BACK_MBPS`, kernel
thấy dưới `KERNEL_MAX` gói của `eth0`/`eth1` trong `WINDOW` giây, phía dây
của engine tăng.

**VLAN** (`accel-vlan`, `accel-vlan-back`). PC1 có thêm 192.168.30.10/24 trong
VLAN 30, như mục "PC1, VLAN 30" của `scripts/hwaccel/bench.md` (macOS:
`ifconfig vlan30 create`, `route add -ifscope vlan30 default 192.168.30.1`).
Script thêm `eth1.30` 192.168.30.1/24 vào zone `lan` tới khi kết thúc, và
iperf3 chạy `-B 192.168.30.10`. `VLAN_PARENT=br-lan` cho `br-lan.30` như trên
LS1046; frame trên cáp `eth1` mang tag 30 cả hai cách. PC2 không cần gì thêm:
board vẫn NAT ra `wan`.

```
IPERF3=iperf3-darwin sh scripts/ls1088/acceptance.sh accel-vlan accel-vlan-back
```

**PPPoE** (`accel-pppoe`, `accel-pppoe-back`, `accel-vlan-pppoe`,
`accel-vlan-pppoe-back`, `accel-redial`). Cần một máy chạy PPPoE server ở đầu
kia cáp `eth0` (module SFP+ 10G RJ45). Người dùng chọn và cắm:

- PC3 (Ubuntu) hay một PC Linux khác, cắm vào `eth0` thay cho PC2;
- một VM Linux bridged trên card Ethernet của Mac PC2;
- board LS1046 với `rp-pppoe-server`.

Trên máy đó, như mục PC2 bước 2 của `scripts/hwaccel/bench.md` (Debian/Ubuntu,
gói `pppoe`; `-k` là PPPoE trong kernel, không có nó thì không qua được vài
trăm Mbps):

```
printf 'noauth\nmtu 1492\nmru 1492\n' | sudo tee /etc/ppp/hwaccel-pppoe-options
sudo pppoe-server -k -I <nic> -L 10.99.0.1 -R 10.99.0.2 -N 1 -O /etc/ppp/hwaccel-pppoe-options
iperf3 -s -D
iperf3 -s -p 5202 -D
```

Script cho `wan` quay PPPoE bằng `hwaccel`/`hwaccel` tới khi kết thúc, rồi
trả `wan` về như cũ. iperf3 server là đầu kia của phiên (10.99.0.1), hoặc
`PPPOE_SERVER`. Máy này không cần route về 192.168.5.0/24: board NAT ra
`pppoe-wan`. Thiếu `-L`/`-R` thì `pppoe-server` lấy mặc định 10.0.0.1 và
10.67.15.1; dùng đúng lệnh trên để khớp route dưới đây.

PC1 phải gửi tới 10.99.0.1 qua board, không qua Wi-Fi hay VPN (mục không
có VLAN gửi theo route của PC1; mục `-vlan-pppoe` đi theo `vlan30`):

```
route -n get 10.99.0.1 | grep interface      # phải ra en0
sudo route -n add 10.99.0.0/24 192.168.5.1
```

```
IPERF3=iperf3-darwin sh scripts/ls1088/acceptance.sh accel-pppoe accel-pppoe-back accel-vlan-pppoe accel-vlan-pppoe-back accel-redial
```

- Mốc của các bản `-back` là `BASE_BACK_MBPS` (592, của PC2). Máy PPPoE gửi
  chậm hơn thì đo chiều đó qua kernel trên cùng bàn (`bmchwaccel disable`
  lúc đang chạy, iperf3 `-R`, rồi `bmchwaccel enable`) và chạy với
  `BASE_BACK_MBPS` bằng số đó. Ngày 2026-10-26, PC3 (Ubuntu trong VMware) gửi
  qua PPPoE chỉ 403 Mbps, qua kernel cũng như qua engine, 0 retransmit.

- `accel-vlan-pppoe` cần cả VLAN 30 của PC1.
- `accel-redial`: một luồng UDP (`DROP_RATE`, tới cổng `DROP_PORT` 5202 của
  server) đi engine qua phiên PPPoE. Board đặt `network.wan.ac` là một tên
  không server nào có, nên pppd kết thúc phiên và không mở được phiên mới,
  trong `WINDOW` giây; luồng bị bỏ lặng lẽ bằng một luật `mangle`. Lúc phiên
  mất, engine không được giữ kết nối nào, cáp `eth0` ra dưới `KERNEL_MAX` gói.
  Rồi tên được gỡ, phiên mới lên (số session in ra; server có thể cấp lại số
  cũ), và iperf3 `-P 4` qua phiên mới phải được tăng tốc như `accel`.
- Chưa có PPPoE server trên bàn thì các mục PPPoE để mở; bài pcap
  (`tests/run.sh functional vlan-pppoe pppoe-redial` của `bmcHwAccelDpdk`) và
  test lõi vẫn chạy trên máy build.

## Chung sống với Feature BMC (`reroute`, `qos`, `qos-back`, `block`, `ftp`, `ipsec-accel`, `ipsec-reorder`, `mwan`, `features`)

Ticket `09`. Cần bố cục engine, `bmchwaccel status` là `on`, PC2 chạy hai
iperf3 server như trên.

```
IPERF3=iperf3-darwin sh scripts/ls1088/acceptance.sh reroute qos qos-back block features features-in
```

- `reroute`: một lần iperf3 `-P 4` PC1 → PC2; board đổi đường tới PC2 hai lần,
  mỗi lần `STALL` giây (5): route blackhole cho 192.168.2.10, rồi neighbour
  của PC2 mang một MAC không ai có. Mỗi lần engine phải rút kết nối trong
  `KEEP_MS` (1000 ms); lúc blackhole không gói nào ra cáp `eth0`; đường đúng
  lại thì kết nối được tăng tốc lại trong `REROUTE_WAIT` giây (30). Script tự
  trả route và neighbour về như cũ, kể cả khi bị ngắt giữa chừng.
- `qos`, `qos-back`: bmcqos trên `wan` ở `QOS_MBPS` (100) cả hai chiều, chỉ
  trong lúc chạy mục; cấu hình bmcqos của board được trả lại.
- `block`: macfilter, client_control, chặn dịch vụ và bmcfido lần lượt chặn
  PC1 giữa một luồng UDP đang đi engine (như mục `block` của LS1046). "Máy
  khác vẫn được tăng tốc" là mục `block-other` dưới đây.

### Máy khác vẫn được tăng tốc (`block-other`)

Cần một máy LAN thứ hai, PC3, cắm vào cổng nào của `br-lan` cũng được (ví dụ
`eth3`). PC3 là máy bị chặn, PC1 ở `eth1` là "máy khác": kết nối có một đầu ở
cổng 1G không bao giờ được giao cho engine, nên chỉ luồng của PC1 đo được trong
engine. PC3 ping PC2 suốt bài để luôn có một kết nối qua board (board ở mode
`nac` thì ping chưa qua được; script chuyển sang `off` trong lúc chạy).

```
# trên PC3
ping -t 192.168.2.10       # Windows; macOS/Linux: ping 192.168.2.10
# trên PC1
PC3=<địa chỉ của PC3> IPERF3=iperf3-darwin sh scripts/ls1088/acceptance.sh block-other
```

Trong lúc iperf3 `-P 4` của PC1 chạy qua engine, PC3 bị chặn lần lượt bằng
macfilter, macfilter mode whitelist chỉ có PC1 trong danh sách, client_control
và bmcfido. Mỗi lần: PC3 mất hết kết nối qua board; mọi luồng của PC1 nằm trong
engine suốt thời gian chặn (board liệt kê engine mỗi 0,1 s); kernel thấy ít hơn
`KERNEL_MAX` gói của `eth1` trong `WINDOW` giây; iperf3 không dừng giây nào.

Bài này không thử engine rút entry của một máy mà giữ entry của máy khác trên
cùng cổng: muốn vậy cả hai máy phải ở `eth1` (cần switch 10G).

Nếu `en0` của PC1 có mask rộng hơn `/24` (ví dụ `/16`), macOS coi 192.168.2.x
là cùng mạng và không đi qua board: thêm route `sudo route -n add -net
192.168.2.0/24 192.168.5.1`.
- `features`, `features-in`: như LS1046 nhưng với Tăng tốc phần cứng bật.

### FTP qua NAT (`ftp`)

Helper FTP của firewall chỉ theo cổng 21, nên server trên PC2 cần `sudo`:

```
# trên PC2, chép scripts/ls1088/ftp-server.py sang trước
sudo python3 ftp-server.py            # cổng 21, file /hwaccel-ftp.bin 64 MB
# trên PC1
IPERF3=iperf3-darwin sh scripts/ls1088/acceptance.sh ftp
```

PC1 tải bằng `curl` ở chế độ passive rồi active (`-P -`), giới hạn `FTP_RATE`
(8M, khoảng 8 s mỗi lần). Firewall của macOS trên PC1 phải cho kết nối vào
(chế độ active: PC2 mở kết nối dữ liệu về PC1 qua NAT của board).

### IPsec (`ipsec-accel`, `ipsec-reorder`)

Cần một đầu IPsec ở phía `wan` chạy strongSwan (từ 2026-11-03 là PC4, Ubuntu
trên máy thật ở `eth0`, dựng bằng `pc4-setup.sh`; trước đó là VM PC3), có một mạng sau nó với một
máy chạy `iperf3 -s` (`IPSEC_TARGET`, vd. 10.20.0.10 trên `lo` của PC3), và
`iperf3 -s` trên chính địa chỉ `wan` của peer (`SERVER`) để đo mốc nối thẳng
ngoài tunnel. Dựng tunnel bằng trang VPN của board, như mục "IPsec qua trang
VPN — ticket 24" của `scripts/hwaccel/bench.md`. Mac cần route tới
`10.20.0.0/24` qua board. `PEER_SSH` là SSH vào peer không mật khẩu, `sudo`
không mật khẩu (đọc `/proc/net/xfrm_stat`, `tcpdump`):

```
SERVER=192.168.2.1 IPSEC_TARGET=10.20.0.10 PEER_SSH=raymond@192.168.2.1 \
	PEER_KEY=$HOME/.ssh/id_ed25519_nhatgithub_cowork IPERF3=iperf3-darwin \
	sh scripts/ls1088/acceptance.sh ipsec-accel ipsec-reorder ipsec-replay idle
```

PC4 chỉ có cổng 1G sau module 10G: cần `tx_limit 'eth0:980'` (mục trên),
không thì lỗi CRC kéo chiều đi xuống.

- `ipsec-accel` đạt khi: iperf3 `-P 4` tới `IPSEC_TARGET` ≥ `IPSEC_MBPS`
  (850); chiều ngược ≥ `ACCEL_PCT` % (95) mức `-R` từ `SERVER` ngoài tunnel;
  kernel thấy < `KERNEL_MAX` gói của `eth0` trong `WINDOW` s; `ipsec_sa` ≥ 2,
  `accelerated` > 0, engine giữ kết nối tới `IPSEC_TARGET`; byte của SA trong
  `ip -s xfrm state` tăng; `XfrmInStateSeqError`, `XfrmInNoStates` của peer
  không đổi. Mỗi lần chạy ghi tải của từng core worker và số chu kỳ mỗi gói
  (thời gian bận của worker chia cho gói vào từ cáp).
- `ipsec-reorder` chỉ đo: iperf3 `-P 8` (kết nối của tunnel trên nhiều
  worker), peer bắt `IPSEC_CAPTURE` gói ESP tới nó và đếm gói tới sau một
  gói có số lớn hơn, lệch tối đa bao nhiêu. Tải từng worker trong dòng kết
  quả cho biết kết nối có thật nằm trên nhiều worker không.
- Số chu kỳ mỗi gói là ước lượng: thời gian bận của mọi worker chia cho mọi gói
  vào từ cáp của các cổng engine (gói dữ liệu và ACK).
- Mục "router rảnh, có tunnel lên" của ticket `16` là mục `idle` chạy khi
  tunnel đang lên và không có traffic (chỉ DPD).
- `ipsec-replay` (ticket `23`): SA vào của `BOARD_CONN` có `replay_window 128`
  trong `ip -d xfrm state` (file `/etc/strongswan.d/bmchwaccel.conf`), engine
  giữ nó và `bmchwaccel sa` liệt kê nó. Với cửa sổ 32, SEC từ chối 1–3 % ESP
  của PC4 và ESP đó lên kernel.

### IPsec: rekey, rơi về kernel, giới hạn (ticket `17`)

Cùng bàn đo và biến như `ipsec-accel`, thêm `BOARD_CONN`, `PEER_CONN` (tên
`conn` của tunnel trong `/etc/ipsec.conf` của board và của peer, mặc định
`t14`). Các mục đọc và sửa cấu hình strongSwan của peer qua `PEER_SSH` (cần
`sudo` không mật khẩu), rồi trả lại như cũ.

```
SERVER=192.168.2.1 IPSEC_TARGET=10.20.0.10 PEER_SSH=karik@192.168.2.1 \
	PEER_KEY=$HOME/.ssh/id_ed25519_nhatgithub_cowork IPERF3=iperf3-darwin \
	XFRMAE=.../ls1088-tools/xfrmae.aarch64 \
	sh scripts/ls1088/acceptance.sh ipsec-rekey ipsec-kill ipsec-disable ipsec-syncd \
		ipsec-limit ipsec-algo ipsec-many
```

- `ipsec-rekey`: peer đặt lifetime CHILD_SA `REKEY_LIFE` (2 phút, rekey trước
  30 s, tức mỗi 90 s; bản gốc lưu ở `/etc/ipsec.conf.t17` của peer) rồi dựng
  lại tunnel. Đo một lượt 30 s không rekey làm mốc, rồi iperf3 `-P 4`
  `REKEY_TIME` s (600). Đạt khi: không giây nào dưới 1 Mbps; tổng ≥
  `ACCEL_PCT` % mốc; có ít nhất `REKEY_MIN` (5) lần rekey; cả SPI ra lẫn SPI
  vào mới của strongSwan có trong `bmchwaccel sa` trong mẫu đó hay mẫu kế
  (mỗi 10 s); engine giữ
  kết nối tới `IPSEC_TARGET` ở mọi mẫu; kernel thấy < `KERNEL_MAX` gói của
  `eth0` giữa hai mẫu; lỗi số thứ tự của peer không đổi. In dòng Mbps từng
  giây.
- `ipsec-kill`: `kill -9` engine khi iperf3 `-P 4` đang chạy `KILL_TIME` s
  (45). Đạt khi: engine lên lại; engine giữ lại SA ra và kết nối; SPI của
  strongSwan trước và sau như nhau; iperf3 chạy hết, chỉ một khoảng ngắt dưới
  1 Mbps, dài tối đa `KILL_GAP` s (10; engine lên lại sau khoảng 7 s); lỗi số thứ tự của peer không đổi. Mục này tính một lần chết của
  engine cho `supervise-engine` (3 lần trong 5 phút thì router khởi động lại).
- `ipsec-disable`: `bmchwaccel disable` khi iperf3 đang chạy, 3 s sau đọc
  trạng thái, rồi `enable`. Đạt khi: tắt thì `off`, `ipsec_sa` = 0, engine
  không giữ kết nối nào; bật thì `on`, engine giữ lại tunnel; SPI không đổi;
  không giây nào dưới 1 Mbps; lỗi số thứ tự của peer không đổi.
- `ipsec-syncd`: `kill -9` daemon. Đạt khi: engine rút hết kết nối và SA trong
  5 s; trong giây kế đó kernel thấy ≥ `KERNEL_MAX` gói của `eth0` (tunnel đi
  qua kernel); supervisor chạy lại daemon và engine giữ lại tunnel; SPI không đổi;
  iperf3 tối đa 1 s dưới 1 Mbps; lỗi số thứ tự của peer không đổi.
- `ipsec-limit` (cần `XFRMAE`: `xfrmae` của ticket `13`, build cho mạch): tắt
  Tăng tốc phần cứng, đặt `oseq` của SA ra trong kernel để engine còn
  `LIMIT_LEFT` số (300000) trước `SA_SEQ_LEAVE` (`2^32 − 2^26 − 2^22`), bật
  lại, rồi iperf3 30 s. Đạt khi: engine nhận SA từ đúng số đó; sau đó engine
  không còn giữ SA ra; syslog có `its sequence numbers near their end`;
  `oseq` của kernel ≥ `SA_SEQ_LEAVE + 2^24`; strongSwan vẫn dùng SPI đó (không
  dựng lại tunnel); không giây nào dưới 1 Mbps; lỗi số thứ tự của peer không
  đổi. Cuối mục peer dựng lại tunnel (`ipsec down`/`up`) để có SA mới.
- `ipsec-algo`: thêm ba tunnel `also=` tunnel của bàn đo, mạng của peer
  10.20.201/202/203.0/24: GCM-256 (`aes256gcm16!`), ChaCha20-Poly1305
  (`chacha20poly1305!`), ESN (`aes256-sha256-esn!`); peer có `10.20.N.10`
  trên `lo` và `iperf3 -s` ở cổng `5300 + N`. Đạt khi: cả bốn tunnel lên;
  `ipsec_sa` = 4 (tunnel của bàn đo và GCM); iperf3 15 s qua từng tunnel chạy
  được; engine giữ cả hai SA và kết nối của tunnel GCM, không giữ SA hay kết
  nối nào của hai tunnel kia.
- `ipsec-many`: như trên với `MANY` − 1 tunnel (255, mạng 10.20.1–255.0/24,
  `aes256-sha256!`). Đạt khi: `MANY` tunnel `INSTALLED` trong `MANY_WAIT` s
  (180); `ipsec_sa` = 2 × `MANY`; iperf3 `-P 2` qua ba tunnel cùng lúc (đầu,
  giữa, cuối) đều chạy và engine giữ kết nối của cả ba; kernel thấy <
  `KERNEL_MAX` gói của `eth0` trong `WINDOW` s; lỗi số thứ tự của peer không
  đổi.
- Tunnel luôn được dựng lại từ phía board (`ipsec up` trên board): sau reboot,
  firewall của board không còn luật nhận IKE từ `wan` (lỗ của ticket bmcwebUI
  03), nên PC3 khởi động thì board không trả lời (`peer not responding`). Rekey
  do PC3 khởi động vẫn qua, vì nó đi trong luồng UDP 4500 board đã mở.
- macOS có thể xoá route tay `192.168.2.0/24` qua board khi mạng của một card
  khác đổi (Wi-Fi): mục nào cũng hỏng vì không tới được PC3. Kiểm bằng
  `route -n get 192.168.2.1` (phải là `en0`, gateway `192.168.5.1`).
- Hai mục cuối cần route của Mac tới cả `10.20.0.0/16` qua board (không chỉ
  `10.20.0.0/24`): `sudo route add -net 10.20.0.0/16 192.168.5.1`.
- Hai mục cuối ghi các tunnel thêm vào giữa hai dòng `# hwaccel:t17` của
  `/etc/ipsec.conf` ở cả hai đầu, cuối mục xoá đi; mục bị ngắt giữa chừng thì
  chạy lại chính mục đó (mỗi lần chạy xoá khối cũ trước).

### IPsec chung sống với Feature BMC (ticket `18`)

Cùng bàn đo và biến như ticket `17` (`IPSEC_TARGET`, `PEER_SSH`, `PEER_KEY`,
`BOARD_CONN`, `PEER_CONN`). `IPSEC_PEER` là địa chỉ peer của tunnel, mặc định
là host của `PEER_SSH`.

```
SERVER=192.168.2.1 IPSEC_TARGET=10.20.0.10 PEER_SSH=karik@192.168.2.1 \
	PEER_KEY=$HOME/.ssh/id_ed25519_nhatgithub_cowork IPERF3=iperf3-darwin \
	sh scripts/ls1088/acceptance.sh ipsec-sweep ipsec-qos ipsec-route ipsec-mtu features
```

- `ipsec-sweep`: lần lượt client_control, macfilter (blacklist) và bmcfido
  (chế độ fido, PC1 không có trong `authorized_table`) chặn chính PC1 khi
  iperf3 `-P 4` của PC1 đang đi qua tunnel. Cả ba chỉ chặn ở `FORWARD`, nên SSH
  của PC1 tới board vẫn chạy. Đạt khi: trước luật engine giữ kết nối tới
  `IPSEC_TARGET` và cáp `eth0` gửi ≥ `ENGINE_MIN / WINDOW` gói/s; từ lúc đặt
  luật tới lúc cáp `eth0` gửi dưới `SWEEP_QUIET` (20) gói trong 0,5 s không
  quá `SWEEP_MS` (1000) ms, và 2 s cuối của lượt nhìn (`SWEEP_LOOK`, 5 s)
  cáp gửi dưới 4 × `SWEEP_QUIET` gói; dưới luật engine không giữ kết nối nào
  tới `IPSEC_TARGET`. Luật được gỡ sau mỗi Feature. bmcfido không tự `sweep`
  khi luật của nó đổi (cron và include của firewall làm, trong vòng một
  phút), nên phần bmcfido gọi `bmchwaccel sweep` sau luật như việc đổi chế độ
  bảo mật phải làm.
- `ipsec-qos`: bmcqos shape `wan` ở `QOS_MBPS` (100). `bmchwaccel keep` chạy
  lại daemon, và daemon để SA của tunnel cho kernel. Đạt khi: `status` có
  `wan` giữ trên CPU cho bmcqos, `ipsec_sa` = 0, tunnel vẫn `INSTALLED` với
  SPI cũ; iperf3 qua tunnel từ `IPSEC_QOS_PCT` (70) tới 105 % của giới hạn
  (cake đếm gói ngoài, gói ESP to hơn gói trong); engine không giữ kết nối
  nào. Tắt bmcqos: engine giữ lại tunnel trong `DAEMON_WAIT` s, và một lượt
  iperf3 được tăng tốc như `ipsec-accel` chấm; lỗi số thứ tự của peer không
  đổi.
  - Cửa sổ chống replay của peer phải ≥ `IPSEC_PEER_WINDOW` (1024). Khi
    tunnel đi kernel, kernel của board mã ESP trên job ring của SEC, và các
    DECO làm xong job của một SA không theo thứ tự, nên ESP ra lệch (đo dưới
    bmcqos 100 Mbps: lệch tới 103; cửa sổ 32 mất ~7000 gói/30 s, 128 còn mất
    436, 1024 không mất gói nào). Engine giữ thứ tự (`ipsec-reorder`: 0).
  - Peer có cửa sổ nhỏ hơn thì mục ghi `/etc/strongswan.d/hwaccel-replay.conf`
    (`charon { replay_window = 1024 }`) trên peer, `ipsec restart` ở đó, rồi
    board dựng lại tunnel. File để lại. Trang VPN ghi yêu cầu này cho người
    vận hành (bmcwebUI `cd3915d6`).
- `ipsec-route`: như `reroute` nhưng với đường tới peer: route blackhole
  `IPSEC_PEER/32`, rồi neighbour của peer mang MAC không ai có. Đạt khi: mỗi
  lần engine rút kết nối qua tunnel trong `KEEP_MS`; trong lúc blackhole cáp
  `eth0` gửi dưới `KERNEL_MAX` gói; đường đúng lại thì kết nối được tăng tốc
  lại trong `REROUTE_WAIT` s; iperf3 chạy hết. Sau đó, dưới iperf3 khác,
  `ip link set eth0 down` `LINK_DOWN` s (5) rồi `up` trên board (SSH đi qua
  `eth1`, không bị ảnh hưởng): 1 s sau khi xuống engine không còn giữ kết nối
  nào tới `IPSEC_TARGET`; lên lại thì engine giữ SA ra của tunnel strongSwan
  đang có trong `LINK_WAIT` s (90; mục không tự dựng lại tunnel), và một lượt
  iperf3 mới được tăng tốc.
- `ipsec-mtu`: ping từ PC1 qua tunnel: có DF thì `IPSEC_PING_FIT` (1394 byte
  dữ liệu, tức MTU tunnel 1422 − 28) có trả lời, từ 1395 và các cỡ của
  `IPSEC_PING_SIZES` (1400 1436 1472) thì không; không DF thì mọi cỡ đó có
  trả lời (kernel phân mảnh ESP, engine ghép, đánh số và phân mảnh lại). UDP
  datagram `IPSEC_UDP_LEN` (3000) byte, không DF, ở `IPSEC_UDP_RATE` (20M)
  mỗi chiều: bên nhận được ≥ 99 %, và router đưa nó vào tunnel phân mảnh ESP
  (`FragCreates` của `/proc/net/snmp` tăng): board ở chiều đi, peer ở chiều
  về. Chiều về đi từ `IPSEC_FAR` (10.20.0.30), một network namespace mục dựng
  trên peer (veth, proxy ARP, `iperf3 -s -p 5310`, `ip_forward` bật tới khi
  xong): peer forward gói đó như một router. Gói peer tự gửi thì kernel của
  nó phân mảnh trước ESP theo MTU tunnel, nên không có ESP phân mảnh. TCP có
  DF (MSS theo cáp của PC1): iperf3 chạy hết, ≥ `IPSEC_TCP_MIN` (100) Mbps.
- `features` chạy lại như mục của LS1046, với tunnel đang lên.

**PPPoE** (`ipsec-pppoe`): bàn đo PPPoE của ticket `10` trên chính peer (PC3
chạy `pppoe-server` như mục VLAN và PPPoE ở trên, cùng card nối `eth0`).
Script cho `wan` quay PPPoE, thêm conn `t18-pppoe` (`also=` tunnel của bàn đo,
hai đầu là địa chỉ của phiên PPPoE) ở cả hai đầu, `ipsec down` tunnel của bàn
đo, rồi dựng `t18-pppoe` từ board. Đạt khi: engine giữ SA ra của nó; iperf3
qua tunnel đạt như `ipsec-accel` chấm và ≥ `ACCEL_PCT` % của
`IPSEC_PAYLOAD_PCT` % (95: phần dữ liệu còn lại trong ESP) iperf3 tới đầu kia
của phiên ngoài tunnel; các ping của `ipsec-mtu` vẫn với cỡ đó: MTU tunnel
qua PPPoE cũng là 1422 (1492 − 68 = 1424 đã chia hết cho 16 của AES-CBC, còn
1500 − 68 = 1432 làm tròn xuống 1424). Cuối mục
conn bị xoá, `wan` về như cũ và board dựng lại tunnel của bàn đo.

```
IPSEC_TARGET=10.20.0.10 PEER_SSH=karik@192.168.2.1 PEER_KEY=... IPERF3=iperf3-darwin \
	IPSEC_PPPOE_DIRECT=192.168.2.1 sh scripts/ls1088/acceptance.sh ipsec-pppoe
```

`IPSEC_PPPOE_DIRECT`: đích của lượt đo ngoài tunnel qua phiên PPPoE (mặc định đầu
kia của phiên, 10.99.0.1). PC1 không có route tới 10.99.0.0/24 qua board thì đặt
một địa chỉ khác của peer mà PC1 route qua board, ví dụ 192.168.2.1: board NAT
nó ra `pppoe-wan`, peer nhận vì địa chỉ đó là của nó.

`PEER_KNOWN_HOSTS`: file known_hosts riêng cho `PEER_SSH`, khi máy ở địa chỉ peer
vừa đổi (PC4 rồi PC3 ở 192.168.2.1) mà không muốn sửa `~/.ssh/known_hosts`.

**VLAN** (`ipsec-vlan`): PC1 có 192.168.30.10 trên VLAN 30 như mục VLAN ở
trên. Script thêm conn `t18-vlan` (`also=` tunnel của bàn đo, mạng của board
là 192.168.30.0/24) ở cả hai đầu và luật firewall của tunnel như trang VPN
làm (`bmc_ipsec_nat`, `bmc_ipsec_forward`, ghi chú `hwaccel t18`), dựng nó
từ board, rồi chạy iperf3 `-B 192.168.30.10`. Đạt như `ipsec-accel`, ≥
`IPSEC_MBPS`. Cuối mục conn và luật bị xoá. PC3 không cần route về
192.168.30.0/24: gói về đi trong tunnel.

**Multi-WAN** (`ipsec-mwan`): bàn đo của mục `mwan` dưới đây (ISP B ở `eth2`).
`wan2` xuống rồi lên (`ifdown`/`ifup`) khi iperf3 `-P 4` đang qua tunnel trên
`wan`. Đạt khi: iperf3 chạy hết, tối đa `MWAN_IPSEC_GAP` (10) s dưới 1 Mbps;
SPI không đổi; engine giữ lại kết nối qua tunnel trong `REROUTE_WAIT` s; và
tunnel thứ hai qua `wan2`: `MWAN_CONN` (một conn của board tới một
strongSwan sau ISP B, ví dụ chính máy ISP B với mạng sau nó trên `lo`) và
`MWAN_IPSEC_TARGET` (một địa chỉ sau nó) `INSTALLED`, iperf3 qua nó chạy
được, engine không giữ SA hay kết nối nào của nó (cổng 1G). Không đặt hai
biến đó thì mục không đạt.

- Các conn `t18-*` nằm giữa hai dòng `# hwaccel:t18 TÊN begin/end` của
  `/etc/ipsec.conf` ở cả hai đầu. Mục bị ngắt giữa chừng thì script xoá
  chúng lúc thoát; nếu còn sót, chạy lại chính mục đó.

### Multi-WAN (`mwan`)

Cần một PC thứ ba làm ISP B ở cổng 1G `MWAN_PORT` (`eth2`), như mục `mwan`
của `scripts/hwaccel/bench.md`: ISP B ở `SERVER2` (192.168.3.10), cả PC2 (ISP A)
và ISP B trả lời cho `MWAN_TARGET` (198.51.100.1) và `MWAN_TARGET2`
(198.51.100.2). PC3 rút từ `eth3` sang `eth2` làm ISP B được; cổng Ethernet
thứ hai của PC2 cũng được. PC1 không cắm vào `eth2`.

```
PC1 192.168.5.10 ── eth1 [br-lan 192.168.5.1] LS1088 [wan]  eth0 SFP+ ── PC2 = ISP A (SERVER)
                                                    [wan2] eth2 1G   ── ISP B 192.168.3.10
```

Trên mỗi ISP (macOS; PC làm cả hai ISP chỉ làm một lần):

```
sudo ifconfig <nic> 192.168.3.10 netmask 255.255.255.0     # chỉ ISP B
sudo ifconfig lo0 alias 198.51.100.1 255.255.255.255
sudo ifconfig lo0 alias 198.51.100.2 255.255.255.255
iperf3 -s -D
iperf3 -s -B 198.51.100.1 -p 5203 -D
```

- Server 5203 gắn (`-B`) vào `MWAN_TARGET`, không phải `MWAN_TARGET2` như
  trên LS1046: ở đây luồng UDP của `mwan-lost` đi `wan`, tới `MWAN_TARGET`.
  Không có `-B`, Mac trả lời UDP từ địa chỉ của card, conntrack không ghép
  được trả lời với luồng, và luồng không vào engine.
- Mỗi ISP phải trả lời ping của board (ping đó là phép kiểm tra Internet của
  WAN ấy): tắt stealth mode của firewall macOS.
- `wan` static không gateway thì mục lấy `SERVER` làm gateway. `SERVER` phải
  khác địa chỉ của board trên `wan`: board static 192.168.2.10 thì PC2 là
  192.168.2.1 và chạy với `SERVER=192.168.2.1`.
- Luồng UDP bị chuyển sang ISP kia giữa chừng, nên server 5203 bận khoảng 2
  phút: chờ chừng đó trước khi chạy lại, hoặc khởi động lại server đó trên
  cả hai ISP.

PC1 gửi tới hai địa chỉ đó qua board; `route -n get 198.51.100.1` phải ra
gateway 192.168.5.1 trên cổng nối `eth1` (thêm `-ifp <nic>` khi cổng khác
của PC1 giữ default route):

```
sudo route -n add -net 198.51.100.0/24 192.168.5.1
```

Multi-WAN phải đang tắt trên board, và không còn tunnel IPsec nào tới ISP A;
mục tự dựng `wan2` rồi trả lại.

```
SERVER=192.168.2.1 IPERF3=iperf3-darwin sh scripts/ls1088/acceptance.sh mwan
```

Trên ISP B, `sudo tcpdump -ni <nic> udp port 5203` thấy luồng tới đúng lúc
Chuyển WAN.

- `mwan-rule`: luồng tới `MWAN_TARGET2` ra `wan2` theo Luật chọn WAN, không
  được tăng tốc (cổng 1G).
- `mwan-lost`: luồng UDP tới `MWAN_TARGET` đi engine qua `wan`; board chặn ping
  kiểm tra `wan` nên `wan` Mất Internet. Sau Chuyển WAN, bmcMultiWAN xóa kết
  nối của `wan` (dòng syslog), trong `WINDOW` giây ít hơn `KERNEL_MAX` gói ra
  cáp `eth0`, luồng ra `wan2`. Sau đó `wan` có Internet lại.

## Nghiệm thu Mốc A (ticket `11`)

Một image build trọn từ cây đã commit, bản phát hành (`LS1088_RELEASE=1`, không
có `dpdk-tools`), nạp bằng `sysupgrade`. Log từng mục vào
`logs/ls1088-t11/`. Bàn đo như trên: PC1 ở `eth1`, PC2 qua module SFP+ ở
`eth0`, board ở security mode `off`, bố cục engine, `on`.

```
docker exec ubuntu20 sh -c 'cd /home/working/github/bmcfirewall_ls1046-ls1088-dpdk && LS1088_RELEASE=1 scripts/ls1088/build.sh image check test > logs/ls1088-build-t11-1.log 2>&1; echo exit=$?'
A=scripts/ls1088/acceptance.sh; L=logs/ls1088-t11
mkdir -p $L; sh $A sysupgrade 2>&1 | tee $L/sysupgrade.log          # image vừa build
sh $A boot firewall ports wan-link 2>&1 | tee $L/boot.log
sh $A accel accel-back 2>&1 | tee $L/accel.log                    # mục 1
sh $A onoff 2>&1 | tee $L/onoff.log                               # mục 3
sh $A idle 2>&1 | tee $L/idle.log                                 # mục 4
sh $A deaths 2>&1 | tee $L/deaths.log                             # mục 5; mạch tự khởi động lại
sh $A restart 2>&1 | tee $L/restart.log                           # mục 5; sau deaths, không trước
sh $A features 2>&1 | tee $L/features.log                         # mục 7
WEBUI_PASS=<mật khẩu admin> sh $A webui webui-ports webui-ports-back 2>&1 | tee $L/webui.log
sh $A carrier 2>&1 | tee $L/carrier.log                           # người rút/cắm cáp eth0
caffeinate -i sh $A soak 2>&1 | tee $L/soak.log                   # 1 giờ
REBOOTS=20 caffeinate -i sh $A reboots 2>&1 | tee $L/reboots.log  # người dùng chọn giờ chạy
```

- Mục 2 (VLAN, PPPoE): `accel-vlan`, `accel-pppoe`, `accel-vlan-pppoe` và các
  bản `-back`, như mục VLAN và PPPoE ở trên; cần VLAN 30 trên PC1 và máy PPPoE
  ở `eth0`.
- PC2 cấp DHCP cho `wan` từ 192.168.2.1 thì board nhận 192.168.2.10, địa chỉ
  mặc định của `SERVER`: chạy mọi mục với `SERVER=192.168.2.1`. PC1 cần route
  192.168.2.0/24 qua board (`sudo route -n add -net 192.168.2.0/24
  192.168.5.1`), không thì iperf3 đi Wi-Fi và báo "unable to connect".
- Các bản `-back` của PPPoE: máy PPPoE gửi chậm hơn PC2 thì lấy mốc trên cùng
  bàn như mục PPPoE ở trên (`bmchwaccel disable`, chạy lại các bản `-back`,
  `bmchwaccel enable`), rồi chạy với `BASE_BACK_MBPS` bằng số đó.
- `repro-single-sender.sh` cả hai chế độ trên image này, theo
  `.scratch/hw-accel-ls1088/bai-test-tren-mach.md` §1–2, sau soak và
  `reboots`: script hủy DPNI của `dprc.1` và giữ `dpni.1` (`eth1`), tức là cần
  bố cục kernel (`bmchwaccel disable`, khởi động lại; `enable` và khởi động
  lại sau cùng). `PEER` là địa chỉ hiện tại của PC1. Chế độ gây lỗi làm SSH
  treo, kernel có thể panic rồi khởi động lại: đăng nhập console serial trước
  khi chạy, và đừng gửi phím nào trong lúc mạch khởi động lại, vì một phím
  dừng autoboot của U-Boot (khi đó gõ `boot`).
- Image phát hành không có `dpdk-tools`: `check-image.sh` với
  `LS1088_RELEASE=1` (trong `build.sh check`) và trên board
  `ls /usr/bin/dpdk-testpmd` phải không có.
