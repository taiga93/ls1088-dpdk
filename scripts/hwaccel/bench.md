# Chuẩn bị bàn test cho `acceptance.sh`

Những gì PC1 và PC2 cần cho các mục VLAN và PPPoE. Board không cần chuẩn bị
gì: script tự thêm interface VLAN và tài khoản PPPoE, rồi trả cấu hình
network và firewall về như cũ khi kết thúc.

Các lệnh Linux đã được chạy trong `tests/qemu-test.sh` (ở đó PC1 và PC2 là
các network namespace). Các lệnh macOS và `pppoe-server` của Debian chưa được
chạy trên bàn test.

## Đấu dây

```
A (các mục mặc định):
PC1 192.168.5.10 ── eth1 [br-lan 192.168.5.1]  LS1046  [wan] eth0 ── PC2 192.168.2.10/24

B (vlan-vlan, vlan-vlan-back):
PC1 ── eth1 [br-lan]  LS1046  [br-lan] eth2 ── PC2, VLAN 20

C (mwan, mwan-in):
PC1 ── eth1 [br-lan]  LS1046  [wan]  eth0 ── ISP A: PC2, 192.168.2.10/24
                              [wan2] eth2 ── ISP B: cổng thứ hai của PC2, hoặc một PC thứ ba, 192.168.3.10/24

D (ospf, ospf-move):
PC1 ── eth1 [br-lan]  LS1046  [Link định tuyến 10.17.1.1] eth2 ── router láng giềng, 10.17.1.2/24
                              [Link định tuyến 10.17.2.1] eth4 ── cổng thứ hai của nó, 10.17.2.2/24 (chỉ ospf-move)

E (bridge, bridge-block; `block` dùng đấu dây A):
PC1 192.168.5.10 ── eth1 [br-lan]  LS1046  [br-lan] eth2 ── PC2 192.168.5.20/24, không VLAN
```

PC1 chạy script và cắm vào cổng `br-lan` nào cũng được. `<nic>` ở dưới là
card Ethernet của PC đang cắm dây vào board.

## br-lan ở 192.168.5.0/24

Firmware khởi động với `br-lan` ở 192.168.5.1/24
(`files/etc/config/network`, giống firmware 24.10), và bàn test giữ nguyên
như vậy: PC1 là 192.168.5.10/24 với router 192.168.5.1. `acceptance.sh` và
mọi lệnh trong file này dùng các địa chỉ đó, nên thẻ vừa ghi mới không cần
sửa gì trên board. Mạng còn lại của PC1 (Wi-Fi) dùng 192.168.1.0/24; hai
mạng không đụng nhau.

Trên macOS: System Settings, Network, Ethernet, Details, TCP/IP; hoặc
`sudo networksetup -setmanual Ethernet 192.168.5.10 255.255.255.0 192.168.5.1`.
PC1 cũng phải gửi tới PC2 qua board, dù default route của nó là gì:

```
route -n get 192.168.2.10 | grep gateway      # phải ra 192.168.5.1
sudo route -n delete 192.168.2.0/24; sudo route -n add 192.168.2.0/24 192.168.5.1
```

Trước ticket 12 bàn test dùng 192.168.10.0/24, và các image build trước đó
khởi động ở 192.168.1.1. Board còn ở địa chỉ khác thì test bằng
`BOARD=<địa chỉ> sh scripts/hwaccel/acceptance.sh ...`. Thẻ ghi trước ticket
12 giữ nguyên toàn bộ cấu hình network qua sysupgrade, với địa chỉ ở dạng
list có độ dài prefix (`192.168.10.1/24`) mà bộ lọc DNS không dùng được: ghi
lại thẻ đó.

Muốn đổi địa chỉ của board thì dùng trang LAN của web UI: địa chỉ là một
`option ipaddr` không có độ dài prefix, và các option DHCP cùng bộ lọc DNS
cũng được đổi theo.

Các mục VLAN dùng VLAN 30 cho PC1 (192.168.30.0/24); script dừng khi một mục
VLAN trùng mạng với `br-lan` hoặc `wan`.

## PC2, đấu dây A

PC2 giữ 192.168.2.10/24 trên `<nic>`, không có gateway.

1. Hai iperf3 server. Server thứ hai dành cho `pppoe-drop`, vì luồng của mục
   này bị cắt giữa chừng và có thể để server bận một lúc, và cho kết nối mới
   của `toggle`.

   ```
   iperf3 -s -D
   iperf3 -s -p 5202 -D
   ```

   Dùng Linux hoặc macOS cho PC2. PC2 chạy Windows 10 trên bàn test này thỉnh
   thoảng mất từng đợt khoảng 5 ms traffic ở 1 Gbps, dù Tăng tốc phần cứng
   bật hay tắt; macOS trên PC1 khi đó cần tới 20 s để hồi lại, và `toggle`
   cùng các mục traffic fail vì lý do không thuộc về board. Với PC2 chạy
   Ubuntu và macOS, các mục đó đều đạt.

   Nếu buộc phải dùng Windows: có thể không có `-D`, nên chạy `iperf3 -s` và
   `iperf3 -s -p 5202` trong hai cửa sổ. Windows không trả lời ping trừ khi
   firewall của nó cho phép; `toggle` ping PC2 mỗi giây. Chạy với quyền
   administrator:

   ```
   netsh advfirewall firewall add rule name="hwaccel ping" protocol=icmpv4:8,any dir=in action=allow
   ```

2. Một PPPoE server (Debian/Ubuntu: gói `pppoe`). Nó trả lời trên cùng sợi
   dây, song song với địa chỉ thường, nên có thể chạy suốt mọi mục. Board
   đăng nhập bằng `hwaccel`/`hwaccel`; `noauth` chấp nhận mọi tài khoản.

   ```
   sudo apt install pppoe
   printf 'noauth\nmtu 1492\nmru 1492\n' | sudo tee /etc/ppp/hwaccel-pppoe-options
   sudo pppoe-server -k -I <nic> -L 10.99.0.1 -R 10.99.0.2 -N 1 -O /etc/ppp/hwaccel-pppoe-options
   ```

   `-k` là PPPoE chạy trong kernel. Không có nó thì mọi gói đi qua một tiến
   trình user trên PC2 và không thể đạt 900 Mbps. Khi wan dùng PPPoE, board
   là 10.99.0.2 và script dùng đầu kia của phiên, 10.99.0.1, làm iperf3
   server: hai server ở trên lắng nghe trên mọi địa chỉ của PC2.

   Dừng bằng `sudo killall pppoe-server pppd`.

## PC1, VLAN 30

PC1 giữ địa chỉ không tag 192.168.5.10 (script tới board qua địa chỉ này) và
có thêm 192.168.30.10/24 trong VLAN 30. Các mục VLAN chạy
`iperf3 -B 192.168.30.10`; những gì PC1 gửi từ địa chỉ đó phải đi ra qua
VLAN, tới gateway 192.168.30.1.

Linux:

```
sudo ip link add link <nic> name <nic>.30 type vlan id 30
sudo ip link set <nic>.30 up
sudo ip addr add 192.168.30.10/24 dev <nic>.30
sudo ip rule add from 192.168.30.10 table 30
sudo ip route add default via 192.168.30.1 table 30
```

macOS (`<nic>` như trong `networksetup -listallhardwareports`, ví dụ `en7`):

```
sudo ifconfig vlan30 create
sudo ifconfig vlan30 vlan 30 vlandev <nic>
sudo ifconfig vlan30 inet 192.168.30.10 netmask 255.255.255.0
sudo route add -ifscope vlan30 default 192.168.30.1
```

Kiểm tra, sau khi script đã thêm VLAN 30 vào board (nó làm việc đó ở mục VLAN
đầu tiên; `ping` trước đó sẽ không có trả lời):

```
ping -S 192.168.30.10 192.168.2.10        # macOS
ping -I 192.168.30.10 192.168.2.10        # Linux
```

Gỡ bằng `sudo ifconfig vlan30 destroy` (macOS) hoặc
`sudo ip link del <nic>.30; sudo ip rule del table 30` (Linux).

## PC2, đấu dây B (VLAN 20)

Chuyển dây của PC2 từ `eth0` sang `eth2`, rồi trên PC2:

```
sudo ip link add link <nic> name <nic>.20 type vlan id 20
sudo ip link set <nic>.20 up
sudo ip addr add 192.168.20.10/24 dev <nic>.20
sudo ip route add 192.168.30.0/24 via 192.168.20.1
```

iperf3 server của đấu dây A vẫn chạy tiếp. Giữa hai VLAN không có NAT, nên
cần route về VLAN 30.

## Chạy

Trước khi chạy, cả hai sợi dây phải có link gigabit: ở đầu kết quả board in
tốc độ của từng cổng và số lần link đổi trạng thái từ lúc boot, và một mục
traffic sẽ báo khi cổng nó đọc dưới 1000 Mbps. Trên PC1, `ifconfig <cổng>`
(macOS) hoặc `ethtool <cổng>` (Linux) cho thấy cùng điều đó từ đầu bên kia.

```
sh scripts/hwaccel/acceptance.sh                            # đấu dây A, khoảng 5 phút
sh scripts/hwaccel/acceptance.sh vlan-vlan vlan-vlan-back   # đấu dây B
```

Để xem VLAN trên cổng trần có khác VLAN trên bridge không, chỉ ra cổng PC1
đang cắm: `VLAN_PARENT=eth1 sh scripts/hwaccel/acceptance.sh vlan-wan`.

## Boot không có địa chỉ MAC (`mac-temp`)

Image phát triển có tám địa chỉ MAC trong môi trường U-Boot
(`02:00:00:46:00:00` tới `:07`); mục `mac` của lần chạy mặc định kiểm tra
rằng các cổng dùng chúng và kernel không phải tự tạo địa chỉ nào.

`mac-temp` dành cho lần boot mà U-Boot không truyền địa chỉ MAC nào. Khi đó
kernel cấp cho mỗi cổng một địa chỉ tạm, tạo từ các fuse ID duy nhất của
SoC, và cảnh báo một lần cho mỗi cổng. Mục này cần console serial. Chưa có
phần nào được chạy trên board.

1. Dừng U-Boot ở dấu nhắc và xóa các biến chỉ cho lần boot này (không
   `saveenv`):

   ```
   setenv ethaddr; setenv eth1addr; setenv eth2addr; setenv eth3addr
   setenv eth4addr; setenv eth5addr; setenv eth6addr; setenv eth7addr
   boot
   ```

2. Trên PC1, đấu dây A. `boot` và hai mục traffic cho thấy Tăng tốc phần cứng
   chạy được với MAC tạm:

   ```
   sh scripts/hwaccel/acceptance.sh mac-temp boot brlan-wan brlan-wan-back
   ```

   `mac-temp` ghi các MAC tạm của lần boot vào `/etc/hwaccel-temp-mac` trên
   board.

3. Reboot, xóa các biến lần nữa như bước 1, rồi chạy
   `sh scripts/hwaccel/acceptance.sh mac-temp`. Mục đạt với dòng `the same as
   before the reboot`.

4. Reboot mà không đụng tới U-Boot và chạy `sh scripts/hwaccel/acceptance.sh mac`.
   Xong thì `rm /etc/hwaccel-temp-mac` trên board.

## Boot với Tăng tốc phần cứng đã tắt (`off-boot`)

`tests/qemu-test.sh` phủ phần không cần FMan: lần boot với `enabled` 0 không
thử nạp các module.

Đấu dây A, PC2 có iperf3 server. Trên PC1:

```
sh scripts/hwaccel/acceptance.sh boot brlan-wan off-boot boot brlan-wan
```

`boot` và `brlan-wan` trước tiên cho thấy `bmchwaccel status: on` và một số
Kết nối đã tăng tốc trong lúc iperf3 chạy. Sau đó `off-boot` chạy
`bmchwaccel disable` trên board, reboot, gửi traffic của `brlan-wan` và chờ
thấy nó trên CPU: status `off`, không có Kết nối đã tăng tốc nào, không
module ASK nào được nạp, bộ đếm per-CPU tăng. Mục kết thúc bằng
`bmchwaccel enable` và một lần reboot nữa. Cả mục mất hai lần boot cộng 30
giây. `boot` và `brlan-wan` phía sau cho thấy board tăng tốc trở lại.

Lần chạy bị ngắt giữa hai lần reboot chỉ để board ở trạng thái tắt khi không
tới được board; còn lại script bật lại, không cần reboot. `bmchwaccel get`
trên board cho biết.

## Thẻ mang microcode công khai (`ucode-public`)

Thẻ phải mang microcode FMan công khai 106.x. Build image như vậy bằng cách
giấu microcode ASK khỏi lần build, rồi ghi cả thẻ từ image đó (sysupgrade
không đổi microcode):

```
docker exec ubuntu20 sh -c 'cd /home/working/github/bmcfirewall_ls1046-hw-accel &&
    ASK_UCODE_DIR=/nonexistent scripts/hwaccel/build.sh image check > logs/hwaccel-build-public.log 2>&1'
```

Log build kết thúc bằng cảnh báo về microcode công khai và `check-image.sh`
đạt với một dòng `WARN`. Đấu dây A, PC2 có iperf3 server. Trên PC1:

```
sh scripts/hwaccel/acceptance.sh ucode-public
```

Mục đạt khi `cdx` từ chối microcode, `bmchwaccel status` báo `unavailable`
với lý do `microcode`, dòng syslog cuối của `bmcHwAccel` nói như vậy, và
lần chạy iperf3 tới được PC2 qua CPU: không kết nối nào được giao cho phần
cứng, bộ đếm per-CPU tăng. Mục này không có ngưỡng throughput. Xong thì build
lại image không có `ASK_UCODE_DIR` và ghi lại thẻ.

## Thời gian chờ firmware của PHY 10G (`boot-time`)

Mục này không cần PC2 và không cần traffic; PC1 trên một cổng br-lan là đủ.
Nó đọc kernel log của lần boot đang chạy, nên đo đúng image đang nằm trên
thẻ: chạy một lần trên image trước thay đổi MDC và một lần trên image mới để
có cả hai con số. Số giây là của kernel log, nên không gồm thời gian của
bootloader; thời gian đó giống nhau ở cả hai lần chạy.

Kernel không nạp gì cho PHY còn giữ firmware. Chưa xem AQR113C trên board
này có giữ firmware qua một lần `reboot` không, nên hãy đo sau khi cấp
nguồn: ngắt nguồn board, cấp lại, chờ tới khi board trả lời, rồi trên PC1:

```
sh scripts/hwaccel/acceptance.sh boot-time
```

Dòng kết quả cho thời gian nạp, tần số MDC kernel đặt và tần số U-Boot để
lại, giây mà các cổng được probe và giây `br-lan` bắt đầu chuyển tiếp; tiếp
theo là các dòng kernel, với giây mà FMan, từng MAC và từng cổng được probe.
Image trước thay đổi không có thời gian nạp trong log: khi đó mục cho thời
gian từ `loading firmware` tới dòng FMan. Dán kết quả của cả hai lần chạy vào
ticket.

Mục fail khi việc nạp lỗi (`CRC mismatch`, `firmware loading failed`), khi
cổng đồng 10G không có PHY Aquantia, hoặc khi kernel mới không đặt tần số
MDC. Với image mới, cũng hãy cắm một thiết bị 10G hoặc 1G vào cổng đồng 10G
và xem link có lên không: `cat /sys/class/net/eth4/speed` trên board.

## Daemon cứ chết liên tục

Không mục nào của `acceptance.sh` phủ phần này; các bước làm bằng tay. Với
thẻ ASK, đấu dây A, PC2 có iperf3 server:

1. Cấp địa chỉ cho `wan`: PC2 không phải DHCP server, và chỉ `acceptance.sh`
   mới cấp cho `wan` địa chỉ 192.168.2.1/24, trong lúc nó chạy. Trên board:

   ```
   cp /etc/config/network /tmp/network.before
   uci set network.wan.proto=static; uci set network.wan.ipaddr=192.168.2.1/24
   uci commit network; /etc/init.d/network reload
   ```

   `ping 192.168.2.10` từ PC1 phải có trả lời, và `bmchwaccel status` phải
   báo `on`, rồi mới làm tiếp. Sau đó trên PC1 chạy
   `iperf3 -c 192.168.2.10 -t 120 -P 4`.
2. Trên board, kill daemon mỗi khi nó chạy lại, cho tới khi nó không lên nữa:

   ```
   while ubus call service list '{"name":"cmm"}' | grep -q '"running": true'; do killall -9 cmm 2>/dev/null; sleep 1; done
   bmchwaccel status; cat /var/run/bmcHwAccel/daemon-starts
   logread | grep bmcHwAccel | tail
   ```

   Vòng lặp kết thúc sau khoảng nửa phút, với 5 lần khởi động. Kết quả chờ
   đợi: `status` báo `unavailable` với lý do `daemon`; syslog có
   `unavailable: its service is not running` (và `turned on` sau nó cho mỗi
   lần daemon kịp trả lời trước khi bị kill lại); iperf3 trên PC1 không hề
   dừng và kết thúc ở tốc độ CPU, không có giây nào 0 Mbps sau khi vòng lặp
   kết thúc.
3. `grep -c PERMANENT /proc/net/nf_conntrack` cho thấy các entry còn giữ dấu
   (giới hạn đã biết, README). `ethtool -S eth1 | grep 'rx packets'` hai
   lần, cách nhau vài giây, cho thấy traffic đang trên CPU.
4. `bmchwaccel apply` khởi động lại daemon: `status` báo `on`, và một lần
   chạy iperf3 mới trở lại khoảng 940 Mbps.

5. Trả `wan` về như cũ: `cp /tmp/network.before /etc/config/network;
   /etc/init.d/network reload` (reboot giữa chừng sẽ mất bản sao; khi đó
   `uci set network.wan.proto=dhcp; uci -q delete network.wan.ipaddr; uci
   commit network`).

Dán kết quả của các bước 2 tới 4 vào ticket.

## Hai lần boot hỏng vì nạp module

`tests/qemu-test.sh` phủ lần boot theo sau chúng, với dấu được ghi bằng tay;
test chạy thật của CLI phủ cách dấu đó hình thành. Trên board, làm bằng tay
như sau để thấy lần boot thật tôn trọng dấu:

```
echo 2 > /etc/bmcHwAccel/loading; sync; reboot
```

Sau khi boot: `lsmod | grep -E 'cdx|fci|auto_bridge'` không in gì,
`bmchwaccel status` báo `unavailable` với `boot_skipped`, `logread | grep
bmcHwAccel` có dòng đó, và router vẫn chuyển tiếp (`brlan-wan` fail ở `says
unavailable, need on` với traffic trên CPU). Sau đó `bmchwaccel enable`:
`status` báo `on` mà không cần reboot và file đã biến mất.

## Tắt và bật lại trong lúc có traffic (`toggle`)

Đã chạy trên board ngày 2026-10-05 với PC2 chạy Ubuntu và macOS: PASS, khoảng
500–670 Mbps qua CPU trong lúc tắt, khoảng 930 Mbps sau khi bật. Với PC2
chạy Windows 10, mục fail với các quãng đứng tới 20 s (xem "PC2, đấu dây
A"). `tests/qemu-test.sh` chỉ cho thấy script trên board chạy tới cuối với
busybox của image; ở đó không có gì được bật tắt.

Đấu dây A, PC2 có iperf3 server. Trên PC1:

```
sh scripts/hwaccel/acceptance.sh boot brlan-wan toggle brlan-wan
```

`toggle` chạy một lần iperf3 78 giây và, trên board, đọc bộ đếm per-CPU qua
ba cửa sổ 10 giây: lúc Tăng tốc phần cứng bật, sau `bmchwaccel disable`, và
sau `bmchwaccel enable`. Mục đạt khi

- trước: dưới 1000 gói tới CPU;
- lúc tắt: `bmchwaccel status` báo `off` với 0 Kết nối đã tăng tốc và CPU
  thấy các gói iperf3 mang trong cửa sổ đó: ít nhất 80 % throughput của nó
  tính theo gói đầy (CPU còn thấy cả các gói xác nhận, nên một lần chạy khỏe
  sẽ cao hơn nhiều);
- bật lại: status là `on`, dưới 1000 gói tới CPU, cùng lần chạy iperf3 đó
  đạt 900 Mbps từ đầu cửa sổ tới hết, và cả bốn stream của nó vẫn mang dữ
  liệu trong 5 giây cuối. iperf3 không tự kết nối lại được, nên điều này nói
  rằng các phiên TCP của nó sống qua cả hai lần chuyển;
- iperf3 đứng nhiều nhất một giây trong lúc tắt, và nhiều nhất một giây từ
  đầu cửa sổ cuối tới hết lần chạy;
- syslog có một dòng `bmcHwAccel` cho lần tắt và một dòng cho lần bật.

Dưới mục, script in Mbps của từng giây của lần chạy, với ba cửa sổ nằm giữa
các dấu `|`, một ping từ PC1 tới PC2 cho mỗi giây, và một lần chạy iperf3
thứ hai tới port 5202 mở kết nối mới vào khoảng giây thứ 4 của cửa sổ tắt.
Khi mục fail, nó còn in, từng giây một, số gói mỗi cổng có link đã nhận và
gửi, và mọi bộ đếm của board thay đổi trong các cửa sổ "on" và "disabled":
drop của cổng, tầng IP, conntrack, các luật INVALID của firewall, backlog
của CPU, `nf_conntrack_tcp_be_liberal`. Dán tất cả.

Dòng kết quả cũng cho số entry conntrack còn giữ dấu `[PERMANENT]` sau khi
tắt (README.md, giới hạn đã biết); đó không phải tiêu chí. `brlan-wan` sau
mục cho thấy một lần chạy mới ở tốc độ đầy đủ.

Lần chạy bị ngắt trong lúc Tăng tốc phần cứng đang tắt sẽ được script bật
lại khi kết thúc, nếu tới được board. `bmchwaccel get` trên board cho biết.

## Sysupgrade giữa hai firmware cùng nền (`sysupgrade`)

Mục này cài một `sysupgrade.bin` lên board đang chạy, giữ cấu hình, chờ
reboot và xem cái gì trở lại. `tests/qemu-test.sh` chạy nó với image trong
QEMU; nó chưa được chạy trên board.

1. Board chạy thẻ ghi từ một bản build của nhánh này có phiên bản image 3.0
   (`uci get system.@system[0].compat_version` trên board). Thẻ ghi trước đó
   sẽ từ chối image; ghi lại thẻ.
2. Đấu dây A, PC2 có iperf3 server. Trên PC1:

   ```
   sh scripts/hwaccel/acceptance.sh sysupgrade boot brlan-wan brlan-wan-back
   ```

   `sysupgrade` mất khoảng ba phút. `boot` và hai mục traffic phía sau cho
   thấy firmware vừa cài có tăng tốc.

Image là `sysupgrade.bin` dưới `bin/` của cây; `FIRMWARE=<file>` chỉ ra image
khác. Ticket yêu cầu nâng cấp sang một bản build khác: ghi thẻ từ một bản
build, rồi build bản thứ hai (commit nào sau đó cũng được, số revision trong
dòng kết quả đổi theo) và chạy mục với image của bản thứ hai. Dòng kết quả
sẽ nói khi image chính là bản đang nằm trên thẻ; mục vẫn đạt, vì nó không so
phiên bản. Nó kiểm tra rằng

- một option nó đặt trước khi nâng cấp vẫn còn, và cấu hình network và
  firewall không đổi,
- một file nó để ngoài cấu hình đã mất, tức root filesystem được ghi mới,
- file kernel (`fitImage` trên phân vùng 1) được ghi trong lúc nâng cấp,
- kernel và root filesystem (phân vùng 2) trên thẻ là của image.

Nó không để lại gì trên board đã lên lại và qua được kiểm tra. Lần chạy bị
ngắt, hoặc board không lên lại kịp, có thể còn giữ
`/etc/config/hwaccel_test` và `/root/hwaccel-not-kept`; lần chạy sau sẽ xóa
chúng, hoặc xóa bằng tay. Các gói đã cài và file ngoài cấu hình không sống
qua sysupgrade.

## Board chạy firmware 24.10 từ chối image (`sysupgrade-old`)

Chưa chạy trên board; `tests/sysupgrade-test.sh` hỏi cùng câu đó với một bản
sao root filesystem của 24.10.

1. Boot board từ thẻ có firmware 24.10, PC1 trên một cổng LAN. Board ở
   192.168.1.1: đặt PC1 là 192.168.1.10/24, tắt Wi-Fi.
2. Script đăng nhập không hỏi mật khẩu. Nếu firmware 24.10 hỏi, đưa key của
   PC1 cho nó một lần:

   ```
   ssh root@192.168.1.1 'cat >> /etc/dropbear/authorized_keys' < ~/.ssh/id_ed25519.pub
   ```

3. Trên PC1:

   ```
   BOARD=192.168.1.1 sh scripts/hwaccel/acceptance.sh sysupgrade-old
   ```

Mục này chép image vào `/tmp` trên board, chạy `sysupgrade -T` với nó (chế
độ thử: không ghi gì lên thẻ) và xóa bản sao. Mục đạt khi board từ chối
image vì phiên bản image và thông báo bảo ghi lại thẻ SD; các dòng dưới kết
quả là những gì board đã nói.

## Một giờ traffic (`soak`)

Chưa chạy trên bàn test. `tests/qemu-test.sh` chạy mục này hai phút với
busybox, kernel log và syslog của image; ở đó không có gì được tăng tốc.

Đấu dây A, PC2 có iperf3 server. PC1 phải thức suốt một giờ: trên macOS
chạy script dưới `caffeinate`, và giữ lại kết quả.

```
mkdir -p logs
caffeinate -i sh scripts/hwaccel/acceptance.sh boot brlan-wan soak 2>&1 | tee logs/a1-soak.log
```

`soak` là một lần chạy iperf3 3600 giây từ PC1 tới PC2, như `brlan-wan`. Cứ
300 giây, và thêm một lần ngay trước khi hết (13 lần), board được đọc như
trong một mục traffic: dưới 1000 gói trên CPU của mỗi cổng trong 10 giây,
`bmchwaccel status` là `on` với Kết nối đã tăng tốc. Mục đạt khi các điều
sau cũng đúng:

- cả lần chạy đạt 900 Mbps, và phút cuối thấp hơn phút đầu nhiều nhất 2 %;
- board vẫn ở cùng lần boot, daemon vẫn là tiến trình cũ và không bị khởi
  động lại, và `cdx`, `fci`, `auto_bridge` vẫn được nạp;
- kernel log không có dòng báo sự cố nào từ lúc bắt đầu (`BUG:`, `Oops`,
  `WARNING:`, call trace, hết bộ nhớ, stall, hoặc một dòng của các module
  ASK hay driver FMan và DPAA có chữ lỗi), và syslog không có dòng
  `bmcHwAccel` nào.

Dưới kết quả, mục in Mbps của từng phút, các dòng kernel bị tính là sự cố
(đánh dấu `!`), 40 dòng kernel cuối của lần chạy, và những gì daemon cùng
`bmcHwAccel` ghi vào syslog. Các dòng của daemon không được chấm: hãy đọc
chúng. Bộ nhớ kernel còn trống ở hai đầu nằm trong dòng kết quả; đó không
phải tiêu chí. Con số tụt hàng chục megabyte là điều cần ghi lại: chạy mục
lần hai và xem nó có tụt nữa không.

Để thử ngắn: `SOAK=300 SOAK_EVERY=60 sh scripts/hwaccel/acceptance.sh soak`.

## Hai mươi lần boot liên tiếp (`reboots`)

Chưa chạy trên bàn test. `tests/qemu-test.sh` chỉ cho thấy mục này reboot
board và đọc lần boot mới.

Đấu dây A, PC2 có iperf3 server; mất khoảng một giờ. Trên PC1:

```
caffeinate -i sh scripts/hwaccel/acceptance.sh reboots 2>&1 | tee logs/a1-reboots.log
```

Mục này reboot board 20 lần. Ở mỗi lần boot nó chờ board, kiểm tra những gì
`boot` kiểm tra (microcode được chấp nhận, `/dev/cdx_ctrl`, `bmchwaccel
status` là `on`, daemon được khởi động một lần), rằng ba module ASK được
nạp, và rằng traffic của `brlan-wan` được tăng tốc, mỗi lần boot một dòng.
Mbps nằm trong dòng đó và không được chấm ở đây: bước 1 của lần nghiệm thu
chấm chúng. Dòng cũng có số dòng kernel của lần boot đó bị tính là sự cố
(như trong `soak`). Số này cũng không được chấm, vì chưa ghi lại một lần
boot tốt của board này in ra những gì: con số nên giống nhau ở cả 20 lần
boot, và lần boot nào khác đi là điều cần xem (`dmesg` trên board).

Mục dừng ở lần boot đầu tiên fail và để board ở lần boot đó, để còn đọc
được log của nó: `dmesg`, `logread` và console serial của lần boot đó được
đưa vào ticket. Chỉ cấu hình network được trả về, như ở cuối mọi lần chạy.
`REBOOTS=3` cho một lần thử ngắn.

## Web UI và các tính năng firewall (`webui`, `features`, `features-in`)

Dành cho image có các gói của firmware 24.10 (ticket 12). Đấu dây A; PC2
không cần gì ngoài `iperf3`. Ghi mới thẻ cho image này (xem "br-lan ở
192.168.5.0/24").

Đã chạy trên board ngày 2026-10-06 (ticket 12): `webui` và `features-in`
đạt, `features` fail như mô tả ở dưới.

**PC1 phải gửi tới PC2 qua board** ("br-lan ở 192.168.5.0/24"): `features`
ping PC2 và `features-in` trả lời nó. `ping -c 2 192.168.2.10` trên PC1 phải
có trả lời trước khi chạy mục nào trong hai mục đó.

Board không có đồng hồ giữ giờ và, trên bàn test này, không tới được NTP
server nào, nên ngày giờ của nó là ngày build. `webui` không bận tâm; trình
duyệt thì có thể.

1. **Web UI.** Mở `https://192.168.5.1:3737` bằng trình duyệt trên PC1
   (chứng chỉ là của chính firmware), đăng nhập, và đổi mật khẩu khi UI yêu
   cầu: tài khoản đi kèm image phải làm việc đó trước khi mở được trang
   nào. Sau đó, với tên và mật khẩu mới:

   ```
   WEBUI_USER=admin WEBUI_PASS='<mật khẩu>' \
     sh scripts/hwaccel/acceptance.sh boot firewall ports webui 2>&1 | tee logs/t12-webui.log
   ```

   `webui` đạt khi đăng nhập thành công, bảy trang của các tính năng
   firewall mở được và bảy request mà các trang đó gọi lúc mở được trả lời
   không lỗi. `http://192.168.5.1` (port 80) cũng phải đưa trình duyệt sang
   web UI; phần này xem bằng tay.

2. **macfilter, client_control, ddos_protect**, với Tăng tốc phần cứng được
   mục tắt đi và bật lại ở cuối. PC2 phải trả lời ping.

   ```
   sh scripts/hwaccel/acceptance.sh features 2>&1 | tee logs/t12-features.log
   ```

   Mục này cần macfilter và ddos_protect đang tắt trên board, như ở thẻ mới.
   **Kết quả chờ đợi: PASS** với image có bản sửa của ticket 22 (`files/` và
   bmcwebUI): dòng blacklist của macfilter và luật của client_control mỗi cái
   chặn được PC1 rồi cho qua lại; với ddos_protect bật, chỉ một phần trong 24
   ping tới board **và** 24 ping đi qua board tới PC2 được trả lời (nhiều
   nhất 18), tắt đi thì gần như tất cả (ít nhất 22). Image trước ticket 22
   cho FAIL với ba lý do: macfilter không chặn, client_control không đặt
   luật, ddos_protect không giới hạn gì. Để so sánh, chạy cùng lệnh đó với
   một board chạy firmware 24.10 (cần
   `ssh root@<board>` không hỏi mật khẩu, như trong "Board chạy firmware
   24.10 từ chối image"); ở đó mục bỏ qua phần Tăng tốc phần cứng.

3. **NAT 1:1 và port forward**, cần một kết nối từ PC2:

   ```
   sh scripts/hwaccel/acceptance.sh features-in 2>&1 | tee logs/t12-features-in.log
   ```

   Mục in, hai lần, một dòng như

   ```
   features-in    NAT 1:1: on PC2 run now:  iperf3 -c 192.168.2.1 -p 5301 -t 2
   ```

   Chạy lệnh đó trên PC2 trong vòng ba phút mỗi lần. Mục đạt khi board cho
   thấy cả hai kết nối được dịch địa chỉ tới PC1. `answered by PC1` nghĩa là
   iperf3 của PC1 đã nhận kết nối; `sent on to PC1, which did not take it`
   vẫn đạt và chỉ ra một firewall trên PC1 (macOS hỏi iperf3 có được nhận
   kết nối không).

## Captive portal và proxy (`portal`, `proxy`)

Dành cho image có captive portal và proxy (ticket 13). Đấu dây A. Ghi mới
thẻ: thẻ giữ cấu hình qua sysupgrade thì giữ luôn security mode nó đang có,
và thẻ từ trước image này thì chưa có mode nào.

**Thẻ mới khởi động ở security mode nac**, như firmware 24.10: DHCP server
của `br-lan` tắt, CoovaChilli cấp cho client LAN địa chỉ trong
192.168.182.0/24, và `br-lan` không chuyển tiếp gì của client chưa đăng
nhập ở portal. PC1 với địa chỉ cố định 192.168.5.10 vẫn tới được chính
board (ssh, web UI), không tới được PC2. Vì vậy mọi mục khác của
`acceptance.sh` chuyển board sang mode off trước, theo cách web UI làm, in

```
net            security mode off instead of nac until the script ends
```

và trả mode về ở cuối. Không phải làm gì bằng tay cho việc đó.

1. **Portal.** PC1 cần hai địa chỉ trên cổng của nó: 192.168.5.10 cho ssh,
   như trước, và một địa chỉ portal cấp. Trên macOS:

   ```
   sudo networksetup -setdhcp Ethernet
   sudo ifconfig <nic> alias 192.168.5.10 255.255.255.0
   ifconfig <nic> | grep 'inet 192.168.182.'       # địa chỉ portal cấp
   sudo route -n delete 192.168.2.0/24; sudo route -n add 192.168.2.0/24 192.168.182.1
   ```

   Trên Linux: `sudo dhclient <nic>` (hoặc `udhcpc -i <nic>`) và
   `sudo ip addr add 192.168.5.10/24 dev <nic>`. Địa chỉ chỉ được cấp khi
   board ở mode nac với CoovaChilli đang chạy, mà CoovaChilli chỉ khởi động
   khi wan có default route. Wan không nhận được địa chỉ qua DHCP (PC2 không
   có DHCP server) thì đặt tay trước, và gỡ sau khi xong:

   ```
   ssh root@192.168.5.1 'uci set network.wan.proto=static; uci set network.wan.ipaddr=192.168.2.1/24; uci set network.wan.gateway=192.168.2.10; uci commit network; /etc/init.d/network reload'
   ssh root@192.168.5.1 'pidof chilli; ip -br addr show tun0'      # sau khoảng 10 giây
   ```

   Lấy địa chỉ cho PC1 như trên, rồi chạy:

   ```
   sh scripts/hwaccel/acceptance.sh boot portal 2>&1 | tee logs/t13-portal.log
   ```

   Mục này cần Tăng tốc phần cứng đang bật. Nó thêm tài khoản
   `hwaccel-test` vào cơ sở dữ liệu người dùng của portal, rồi xóa đi. Mục
   đạt khi, trước khi đăng nhập, một request HTTP của PC1 tới PC2 được trả
   lời bằng redirect tới `http://bmc.lan/portal.html`, PC2 không trả lời
   ping nào của PC1 và board chưa chuyển tiếp gì của PC1; sau khi đăng nhập
   qua script của trang portal, portal liệt kê PC1 là đã được phép và PC2
   trả lời; sau khi đăng xuất, PC2 lại ngoài tầm với. PC2 không cần web
   server cho mục này, chỉ cần trả lời ping.

   Bằng tay, một lần: với PC1 chỉ dùng DHCP, mở một trang `http://` bất kỳ
   trong trình duyệt. Trang portal phải hiện ra, và sau khi đăng nhập bằng
   một người dùng tạo ở trang "Captive portal" của web UI, trình duyệt phải
   ra được ngoài.

   Sau đó trả PC1 về địa chỉ cố định
   (`sudo networksetup -setmanual Ethernet 192.168.5.10 255.255.255.0 192.168.5.1`)
   và route tới PC2 qua 192.168.5.1.

2. **Proxy.** PC2 phục vụ một file qua HTTP, trên một port mà bộ theo dõi
   file HTTP biết (80, 8080, 8000 hoặc 8888; mục thêm port khác vào bộ theo
   dõi khi `HTTP_PORT` chỉ ra):

   ```
   mkdir -p /tmp/hwaccel-www && cd /tmp/hwaccel-www
   dd if=/dev/urandom of=hwaccel-proxy.bin bs=1048576 count=2
   python3 -m http.server 8080
   ```

   File phải từ 1 MB tới 5 MB: bộ quét của proxy (`squidclamav`, `maxsize 5M`
   như trên firmware 24.10) không quét file lớn hơn 5 MB và cho nó qua, nên
   với file lớn hơn PC1 nhận HTTP 200 và mục báo FAIL (đã thấy trên board
   ngày 2026-10-09 với file 64 MB).

   Trên PC1, với địa chỉ cố định:

   ```
   sh scripts/hwaccel/acceptance.sh boot proxy 2>&1 | tee logs/t13-proxy.log
   ```

   Mục này cần Tăng tốc phần cứng đang bật. Nó bật bộ theo dõi file HTTP cho
   PC1 và đưa lượt tải của PC1 sang squid bằng một luật REDIRECT (điều
   firmware làm cho port 80 và 443 khi antivirus được bật). Mục đạt khi
   board tự trả lời PC1, tự mở kết nối riêng tới PC2, hỏi ICAP server, và
   không kết nối nào được tăng tốc.

   **PC1 không nhận được file theo đường đó, và điều đó là đúng dự kiến**:
   image không có ClamAV (firmware 24.10 cũng không có), dịch vụ antivirus
   không quét được, và squid được cấu hình không cho gì qua khi chưa quét,
   nên PC1 nhận trang lỗi của squid (HTTP 500). Dòng kết quả nói như vậy.
   Trên board có ClamAV đang chạy, mục sẽ đòi cả file và dòng log của bộ
   theo dõi cho nó.

   Sau đó mục gỡ luật và tải thêm một lần. Phần đó, `without squid (not
   judged)`, cho thấy bộ theo dõi có ghi lại lượt tải mà Tăng tốc phần cứng
   chuyển tiếp hay không: nó đọc `br-lan` trên CPU, và Kết nối đã tăng tốc
   không đi qua đó sau mấy gói đầu. `logged by the tracker 0 time(s)` cùng
   `1 accelerated` là trường hợp đó; trên firmware 24.10, và trong
   `tests/qemu-test.sh`, lượt tải như vậy được ghi lại. Bộ theo dõi nên làm
   gì bên cạnh Tăng tốc phần cứng thì chưa quyết (ticket 13).

## Giữ traffic trên CPU và bmcqos (`keep-mark`, `qos`, `qos-back`, `qos-vlan-vlan`)

Dành cho image có bmcqos (ticket 15). Sysupgrade từ một image cùng nền là
đủ. PC2 chạy Linux hoặc macOS với cả hai iperf3 server (`iperf3 -s` và
`iperf3 -s -p 5202`).

1. **Riêng cơ chế**, đấu dây A. Chưa có phần nào được chạy trên board: bước
   này quyết định cơ chế có được dùng hay không.

   ```
   sh scripts/hwaccel/acceptance.sh boot keep-mark brlan-wan 2>&1 | tee logs/t15-keep-mark.log
   ```

   `keep-mark` đặt trên board một luật gắn bit `0x10000` vào conntrack mark
   của mọi kết nối tới port 5202, gửi tới port đó rồi tới port 5201. Mục
   đạt khi các kết nối có mark không được giao cho phần cứng và cả cổng wan
   lẫn các cổng br-lan đều đưa gói lên CPU (không chiều nào được tăng tốc),
   trong khi các kết nối tới port 5201 được tăng tốc như trong `brlan-wan`.
   Mbps trên CPU của nó được in ra, không chấm.

   Nếu mục fail vì kết nối có mark vẫn được giao cho phần cứng, tức daemon
   không nhìn mark, và phương án dự phòng của ticket được áp dụng (bật
   bmcqos thì tắt toàn bộ Tăng tốc phần cứng); dừng ở đây và dán kết quả.

2. **bmcqos trên wan**, đấu dây A:

   ```
   sh scripts/hwaccel/acceptance.sh qos qos-back brlan-wan 2>&1 | tee logs/t15-qos.log
   ```

   Mỗi mục bật bmcqos cho wan ở 100 Mbit/s cả hai chiều, chỉ trong mục đó,
   rồi trả cấu hình bmcqos của board về như cũ. Mục đạt khi `bmchwaccel
   status` liệt kê wan là được giữ trên CPU cho bmcqos, iperf3 nằm trong
   khoảng 80 tới 105 Mbps, không kết nối nào tới PC2 nằm trong phần cứng, và
   status không còn liệt kê gì khi bmcqos tắt lại. `brlan-wan` phía sau cho
   thấy wan được tăng tốc trở lại. Tăng tốc phần cứng được khởi động lại
   khi bmcqos bật và tắt: các kết nối đang mở vẫn sống.

3. **VLAN tới VLAN với bmcqos trên wan**, đấu dây B (PC2 chuyển sang `eth2`,
   trong VLAN 20):

   ```
   sh scripts/hwaccel/acceptance.sh qos-vlan-vlan 2>&1 | tee logs/t15-qos-vlan.log
   ```

   Mục đạt như `vlan-vlan`, 900 Mbps và không qua CPU, với bmcqos bật cho
   wan. Với hai PC, không đo được giới hạn trên wan và traffic VLAN trong
   cùng một giây; bước 2 và 3 cho thấy từng cái với bmcqos đang bật.

Bằng tay, để thấy việc đăng ký đi theo cấu hình:

```
uci set bmcqos.global.enabled=1; uci commit bmcqos; /etc/init.d/bmcqos restart
bmchwaccel status          # on_cpu: wan eth0, bmcqos
uci set bmcqos.global.enabled=0; uci commit bmcqos; /etc/init.d/bmcqos restart
bmchwaccel status          # on_cpu: []
```

## Multi-WAN với hai WAN (`mwan`, `mwan-in`)

Dành cho image của ticket 16 (sysupgrade từ một image cùng nền là đủ), đấu
dây C. Multi-WAN phải đang tắt trên board, như ở thẻ vừa ghi mới: các mục
tự dựng hai WAN riêng qua `bmcmultiwan` và trả cấu hình Multi-WAN về như
cũ. Chưa có phần nào được chạy trên board; `tests/qemu-test.sh` chạy cả hai
mục mà không có Tăng tốc phần cứng.

Hai PC đóng vai hai ISP. ISP A là PC2 như ở đấu dây A. ISP B nằm trên cổng
`eth2` của board (`MWAN_PORT`); mục lấy cổng này ra khỏi `br-lan` và biến nó
thành `wan2`, 192.168.3.1/24 với gateway 192.168.3.10. Một PC có hai cổng
Ethernet (USB adapter cũng được) có thể làm cả hai ISP. PC1 phải nằm trên
một cổng `br-lan` khác `eth2`.

1. **Mỗi ISP** trả lời cho hai địa chỉ đóng vai Internet, chạy ba iperf3
   server và trả lời ping của board; ping đó là phép kiểm tra Internet của
   board cho WAN ấy. PC làm cả hai ISP chỉ cần làm việc này một lần.

   ```
   # Linux
   sudo ip addr add 192.168.3.10/24 dev <nic>                 # chỉ ISP B
   sudo ip addr add 198.51.100.1/32 dev lo
   sudo ip addr add 198.51.100.2/32 dev lo
   # macOS
   sudo ifconfig <nic> 192.168.3.10 netmask 255.255.255.0     # chỉ ISP B
   sudo ifconfig lo0 alias 198.51.100.1 255.255.255.255
   sudo ifconfig lo0 alias 198.51.100.2 255.255.255.255
   # cả hai
   iperf3 -s -D
   iperf3 -s -p 5202 -D
   iperf3 -s -B 198.51.100.2 -p 5203 -D
   ```

   Server thứ ba dành cho luồng UDP của `mwan-lost`. Nó phải được gắn (`-B`)
   vào đúng địa chỉ mà luồng gửi tới: iperf3 server lắng nghe trên mọi địa
   chỉ sẽ trả lời UDP từ địa chỉ của cổng Ethernet, và board không coi đó
   là trả lời của luồng. Luồng này bị chuyển sang ISP kia giữa lúc đang
   chạy, nên server của nó không bao giờ biết luồng đã kết thúc và bận tới
   2 phút: chờ chừng đó trước khi chạy lại `mwan`, hoặc khởi động lại
   server đó.

   Không ISP nào cần gateway: board masquerade về địa chỉ của nó trên WAN
   đó.

2. **PC1** gửi tới hai địa chỉ đó qua board (macOS; trên Linux
   `sudo ip route add 198.51.100.0/24 via 192.168.5.1`):

   ```
   sudo route -n add 198.51.100.0/24 192.168.5.1
   ```

3. **Bốn kết quả của `mwan`**, khoảng 5 phút:

   ```
   sh scripts/hwaccel/acceptance.sh boot mwan brlan-wan 2>&1 | tee logs/t16-mwan.log
   ```

   | Kết quả | Cho thấy điều gì |
   |---|---|
   | `mwan-default` | kết nối không khớp Luật chọn WAN nào (tới 198.51.100.1) được tăng tốc và ra qua `wan` |
   | `mwan-rule` | kết nối khớp Luật chọn WAN của mục (tới 198.51.100.2) được tăng tốc và ra qua `wan2` |
   | `mwan-lost` | `wan2` Mất Internet trong lúc có một luồng UDP đã tăng tốc: sau Chuyển WAN không còn gói nào của nó rời `eth2`, nó rời `eth0`, và một kết nối mới được tăng tốc qua `wan` |
   | `mwan-back` | `wan2` có lại Internet: kết nối đang mở ở lại `wan`, kết nối mới quay về `wan2`, cả hai đều được tăng tốc |

   Board tự làm cho `wan2` Mất Internet, bằng cách chặn chính các ping của
   nó tới ISP B: link, route và ISP B vẫn y nguyên, nên chỉ có Chuyển WAN
   mới đưa được một kết nối ra khỏi `wan2`. Không ai phải đụng tới dây hay
   ISP B trong lúc mục chạy. Một Chuyển WAN ở đây mất khoảng 15 s (2 vòng
   ping, trong khi mặc định của firmware là 3 vòng để Mất Internet và 5
   vòng để có lại).

   Số gói rời một cổng WAN được đọc từ tổng của cổng trên board, tổng này
   gồm cả những gì phần cứng gửi; bắt gói trên ISP cho thấy cùng điều đó từ
   bên ngoài, ví dụ trên ISP B trong lúc `mwan-lost` chạy:

   ```
   sudo tcpdump -ni <nic> udp port 5203      # dừng lại ở Chuyển WAN
   ```

   `mwan-lost` fail với "connections still flow into the WAN that is Mất
   Internet" khi daemon vẫn giữ một kết nối trong phần cứng dù entry
   conntrack của nó đã bị xóa, và với "removed no connection" khi
   bmcMultiWAN không xóa gì (`logread | grep bmcMultiWAN` có một dòng cho
   mỗi Chuyển WAN và một dòng với số kết nối đã xóa). Dán kết quả trong cả
   hai trường hợp.

   `brlan-wan` phía sau cho thấy board lại không có Multi-WAN.

4. **Kết nối đi vào qua `wan2`**, cần một người ngồi ở ISP B:

   ```
   sh scripts/hwaccel/acceptance.sh mwan-in 2>&1 | tee logs/t16-mwan-in.log
   ```

   Mục forward port 5302 của `wan2` tới một iperf3 server nó khởi động trên
   PC1 (port 5301; firewall trên PC1 phải cho vào), in lệnh cho ISP B và
   chờ lệnh đó 3 phút:

   ```
   iperf3 -c 192.168.3.1 -p 5302 -B 198.51.100.2 -t 60 -P 4
   ```

   `-B` làm cho kết nối đi từ một địa chỉ nằm ngoài mạng của `wan2`, như
   một kết nối từ Internet; trả lời cho một địa chỉ nằm trong mạng đó sẽ ra
   `eth2` dù Multi-WAN làm gì. Mục đạt khi kết nối đó nằm trong phần cứng
   và các trả lời của nó rời `eth2`, không rời `eth0`, là cổng mà Chính
   sách WAN mặc định ưu tiên.

Bằng tay, trên board đã cấu hình Multi-WAN, có thể theo dõi một Chuyển WAN
bằng:

```
bmcmultiwan status
logread -f | grep bmcMultiWAN
cmm -c 'query connections'
```

## Định tuyến động khi đổi route (`ospf`, `ospf-move`)

Dành cho ticket 17, đấu dây D; image của ticket 16 là đủ, không cần build
lại. OSPF phải đang tắt trên board, như ở thẻ vừa ghi mới: các mục tự tạo
Link định tuyến và bật OSPF qua `bmcdynrouting`, rồi trả cấu hình Định tuyến
động về như cũ. Chưa có phần nào được chạy trên board; `tests/qemu-test.sh`
chạy cả hai mục với FRR thật, không có Tăng tốc phần cứng.

Router láng giềng là một máy Linux chạy FRR: một PC, hoặc một máy ảo Linux
trên PC2 với card mạng ở chế độ bridged vào đúng cổng Ethernet đang cắm vào
board (OSPF dùng multicast 224.0.0.5; chế độ NAT của máy ảo không dùng
được; `ospf-move` cần máy ảo có hai card, mỗi card bridged vào một cổng
Ethernet riêng). Nó đóng luôn vai mạng chi nhánh: địa chỉ 10.17.0.1 trên loopback của
nó là mạng mà board học qua OSPF, và các iperf3 server nằm ở đó. `ospf` chỉ
cần một dây (`eth2`); `ospf-move` cần thêm dây thứ hai (`eth4`) tới cổng
Ethernet thứ hai của cùng máy đó (USB adapter cũng được). PC1 phải nằm trên
một cổng `br-lan` khác hai cổng này.

1. **Router láng giềng**, địa chỉ và iperf3 (`<nicA>` cắm vào `eth2`,
   `<nicB>` vào `eth4`):

   ```
   sudo ip addr add 10.17.1.2/24 dev <nicA>
   sudo ip addr add 10.17.2.2/24 dev <nicB>                   # chỉ ospf-move
   sudo ip addr add 10.17.0.1/32 dev lo
   sudo sysctl -w net.ipv4.conf.all.rp_filter=2
   iperf3 -s -D
   iperf3 -s -B 10.17.0.1 -p 5203 -D
   ```

   `rp_filter=2` cần cho `ospf-move`: sau khi board đổi đường, gói của PC1
   tới qua `<nicB>` trong khi router láng giềng vẫn trả lời qua `<nicA>`;
   với `rp_filter=1` nó bỏ các gói đó. Server thứ hai dành cho luồng UDP
   của `ospf-withdrawn` và phải được gắn (`-B`) vào 10.17.0.1, cùng lý do
   như ở `mwan-lost`; sau một lần chạy nó có thể bận tới 2 phút.

2. **FRR trên router láng giềng** (Ubuntu/Debian:
   `sudo apt install frr iperf3`, cài trước bước 1).
   Bật `ospfd` rồi ghi cấu hình:

   ```
   sudo sed -i 's/^ospfd=no/ospfd=yes/' /etc/frr/daemons
   sudo tee /etc/frr/frr.conf <<'EOF'
   router ospf
    ospf router-id 10.17.0.1
   interface <nicA>
    ip ospf area 0
    ip ospf network point-to-point
    ip ospf cost 10
   interface <nicB>
    ip ospf area 0
    ip ospf network point-to-point
    ip ospf cost 100
   interface lo
    ip ospf area 0
   EOF
   sudo systemctl restart frr
   ```

   `point-to-point` là bắt buộc: board đặt kiểu đó cho mọi Link định tuyến,
   và hai đầu khác kiểu thì không thành láng giềng. Hello và dead giữ mặc
   định (10 s và 40 s), board cũng vậy. Khối `interface <nicB>` chỉ cần cho
   `ospf-move`. Firewall của máy đó (ufw, firewalld) phải cho giao thức 89
   và các port iperf3 đi vào, hoặc tắt nó trong lúc test.

3. **PC1** gửi tới mạng chi nhánh qua board (macOS; trên Linux
   `sudo ip route add 10.17.0.0/24 via 192.168.5.1`):

   ```
   sudo route -n add 10.17.0.0/24 192.168.5.1
   ```

4. **Ba kết quả của `ospf`**, khoảng 4 phút, một dây:

   ```
   sh scripts/hwaccel/acceptance.sh boot ospf 2>&1 | tee logs/t17-ospf.log
   ```

   | Kết quả | Cho thấy điều gì |
   |---|---|
   | `ospf-learned` | board và router láng giềng thành láng giềng OSPF, kernel có route tới 10.17.0.1 qua `eth2`, và traffic của PC1 tới đó được tăng tốc qua Link định tuyến, không NAT |
   | `ospf-withdrawn` | board thôi nghe OSPF của láng giềng trong lúc có một luồng UDP đã tăng tốc: khi OSPF rút route (tối đa 40 s), không còn gói nào của luồng rời `eth2` |
   | `ospf-back` | board nghe lại láng giềng: route quay về và một kết nối mới lại được tăng tốc qua `eth2` |

   Board tự làm mất láng giềng, bằng cách chặn các gói OSPF đi vào: dây và
   router láng giềng vẫn y nguyên, nên chỉ có việc rút route mới đưa được
   kết nối ra khỏi `eth2`. Không ai phải đụng tới router láng giềng trong
   lúc mục chạy. Trong `ospf-withdrawn` kết quả ghi board gửi tới
   10.17.0.1 qua cổng nào sau khi route mất: cổng `wan` khi board có
   default route (script đặt gateway cho `wan`, nên có khi `eth0` có link),
   hoặc `no port` khi không có (bàn test này, `eth0` không cắm dây).

   Sau khi mục chạy xong, `bmcdynrouting link list` trên board phải rỗng
   và `eth2` lại là cổng của `br-lan`. Đấu dây D không cần PC2 trên `eth0`;
   nếu PC2 vẫn cắm ở đó, thêm `brlan-wan` vào cuối lệnh để thấy board vẫn
   tăng tốc như trước.

5. **Hai kết quả của `ospf-move`**, khoảng 3 phút, hai dây:

   ```
   sh scripts/hwaccel/acceptance.sh ospf-move 2>&1 | tee logs/t17-ospf-move.log
   ```

   | Kết quả | Cho thấy điều gì |
   |---|---|
   | `ospf-moved` | dưới một lần chạy iperf3 (4 phiên TCP) đang tăng tốc qua `eth2`, cost của `eth2` được nâng lên trên cost của `eth4`: route đổi next-hop sang `eth4`, traffic rời `eth4` thay vì `eth2`, vẫn được tăng tốc, và cả bốn phiên TCP còn chạy tới cuối |
   | `ospf-ecmp` | hai Link định tuyến cùng cost (route có hai next-hop): chỉ ghi lại route, số gói rời mỗi cổng và tốc độ; không tính vào `RESULT` |

   Cost được đổi trong daemon OSPF đang chạy (`vtysh`), không qua
   `bmcdynrouting`: lệnh `ospf set` khởi động lại daemon, làm mất láng
   giềng và rút route trước khi học lại, tức là thành trường hợp của
   `ospf-withdrawn`. Dòng `Mbps each second` dưới `ospf-moved` cho thấy
   từng giây của lần chạy; lúc đổi đường là khoảng giây 20.

6. **Bằng tay**, hai trường hợp script không tự làm được vì phải đụng tới
   router láng giềng. Bật OSPF trên board (web UI, hoặc các lệnh dưới), cho
   PC1 chạy `iperf3 -c 10.17.0.1 -u -b 100M -l 1200 -p 5203 -t 120`, rồi
   làm một trong hai việc:

   - tắt OSPF của láng giềng: `sudo systemctl stop frr` trên router láng
     giềng. Route mất sau tối đa 40 s.
   - rút dây `eth2`. Route mất ngay; kernel không báo việc này theo cùng
     một đường như khi OSPF rút route, nên đây là một trường hợp riêng.

   ```
   # trên board, trước khi thử
   bmcdynrouting router-id set --router-id 10.17.1.1
   bmcdynrouting link add eth2 10.17.1.1/24
   bmcdynrouting ospf set --enabled 1 --interface lan --passive 1 --interface link_eth2
   iptables -I OUTPUT -p icmp --icmp-type destination-unreachable -j DROP
   # trên board, sau khi thử xong
   iptables -D OUTPUT -p icmp --icmp-type destination-unreachable -j DROP
   bmcdynrouting ospf set --enabled 0 --redistribute-connected 0
   bmcdynrouting link del eth2
   bmcdynrouting router-id set --router-id ''
   ```

   Luật `iptables` giữ cho PC1 tiếp tục gửi: khi route mất, board trả lời
   "destination unreachable" và iperf3 dừng ngay, lúc đó bộ đếm của `eth2`
   đứng yên dù phần cứng làm gì. Chỉ đọc bộ đếm khi iperf3 trên PC1 vẫn
   đang chạy.

   Theo dõi trên board:

   ```
   bmcdynrouting status ospf neighbors
   ip -4 route show proto 188
   cmm -c 'query connections'
   cat /sys/class/net/eth2/statistics/tx_packets      # đứng yên khi không còn gói nào rời eth2
   ```

## ddos_protect và thống kê web UI (`stats`, `stats-back`) — ticket 18

Dành cho image nền mới có web UI (ticket 12). Đấu dây A: PC2 chạy cả hai
iperf3 server (`iperf3 -s` ở 5201 và `iperf3 -s -p 5202`). Board đang bật
Tăng tốc phần cứng. Trong lúc chạy mục này chỉ để PC1 nối vào LAN: mục cộng
byte nhận của mọi cổng br-lan, nên một máy LAN khác đang chạy traffic sẽ làm
sai con số.

### Thống kê trên web UI khi có Kết nối đã tăng tốc (ô 3, 4)

```
sh scripts/hwaccel/acceptance.sh boot stats stats-back 2>&1 | tee logs/t18-stats.log
```

Mỗi mục cho PC1 gửi tới PC2 như `brlan-wan`, kèm một luồng UDP nhỏ bên cạnh
để bảng kết nối có cả một mục UDP; luồng TCP phải được tăng tốc. Mục đọc
đúng cái script mà web UI gọi (`get_net_stats.sh`) hai lần, cách nhau
`WINDOW` giây, và chấm đạt khi:

- số kết nối tổng / TCP / UDP mà web UI báo khớp (trong khoảng `STATS_SLACK`)
  với bảng conntrack của kernel mà mục đọc ngay sau đó — kết nối đã tăng tốc
  vẫn nằm trong bảng nên vẫn được đếm (ô 3);
- byte của cổng wan (chiều gửi) và của các cổng br-lan gộp lại (chiều nhận)
  mỗi bên tăng trong khoảng `STATS_LOW`–`STATS_HIGH` phần trăm lượng iperf3
  đã tải trong cửa sổ đó; một bộ đếm không thấy traffic đã tăng tốc sẽ đứng
  gần 0 trong khi vẫn có hàng Gbps chạy qua (ô 4). `stats-back` làm chiều
  ngược lại (`iperf3 -R`): wan nhận, br-lan gửi.

Nếu muốn xem thẳng con số của web UI:

```
bash /etc/bmcweb/backend/scripts/network/get_net_stats.sh
```

`interfaces[]` lấy từ `/proc/net/dev`; với cổng vật lý (eth0…eth5) kernel của
ASK đã cộng cả byte phần cứng chuyển giúp, nên số này gồm cả phần đã tăng
tốc, không chỉ phần lên CPU. `sessions` lấy từ `conntrack -L`.

### Không có byte theo từng kết nối (ô 5)

Đã rà firmware: chỉ `get_net_stats.sh` đọc `conntrack -L`, và nó chỉ dùng cho
số kết nối và số phiên theo IP nguồn, không hiển thị trường `bytes=` của từng
kết nối. Không có chỗ nào khác hiển thị byte theo từng kết nối từ conntrack.

### Giới hạn flood của ddos_protect — đã chuyển sang ticket 22

Quyết định 2026-10-08: ô 1 (flood SYN/ICMP/UDP bị giới hạn) chuyển sang ticket
`22`, và `ddos_protect` giới hạn **cả traffic chuyển tiếp**, không chỉ gói tới
router. Ticket `22` đã sửa code: chain `FW_DOS_POLICY` được nối vào đầu
`INPUT` và đầu `FORWARD`, giới hạn gói vào từ interface cấu hình (`br-lan` như
xuất xưởng). Mức giới hạn, chung cho gói tới router và gói chuyển tiếp:

| Loại gói | Giới hạn |
|---|---|
| Kết nối SSH mới (TCP SYN tới port 22) của một nguồn | kết nối thứ 5 trong 60 giây bị bỏ |
| TCP SYN | 20 gói/giây, burst 40 |
| UDP của luồng chưa có chiều trả lời | 100 gói/giây, burst 150 |
| ICMP echo request (ping) | 1 gói/giây, burst 5 |

**Ô 1 — phần ICMP** do mục `features` chấm (ping tới board và ping qua board
tới PC2, xem "macfilter, client_control, ddos_protect" ở trên). **Phần SYN và
UDP là bước tay** vì cần công cụ flood trên PC1 (ví dụ `hping3` hay `nping`;
PC Windows dùng `nping` của Nmap). Bật ddos_protect trên web UI, rồi với mỗi
đích — board (`192.168.5.1`) và PC2 — làm hai phép đo 10 giây và đọc bộ đếm
của chain trên board trước và sau:

```
ssh root@192.168.5.1 'iptables -Z FW_DOS_POLICY'
nping --tcp --flags syn -p 80 --rate 200 -c 2000 <đích>      # flood SYN
ssh root@192.168.5.1 'iptables -nvxL FW_DOS_POLICY'
ssh root@192.168.5.1 'iptables -Z FW_DOS_POLICY'
nping --udp -p 9 --rate 500 -c 5000 <đích>                   # UDP không có chiều trả lời
ssh root@192.168.5.1 'iptables -nvxL FW_DOS_POLICY'
```

Đạt khi: với SYN, luật `RETURN` đếm khoảng 20 gói/giây (cộng burst 40) và luật
`DROP` ngay dưới nó đếm phần còn lại; với UDP, khoảng 100 gói/giây (cộng burst
150) qua luật `RETURN`, phần còn lại ở luật `DROP`. Port UDP 9 trên PC2 phải
không có gì trả lời (nếu có trả lời, luồng thành "đã có chiều trả lời" và
không còn bị giới hạn — đúng thiết kế). Tắt ddos_protect sau khi đo.

- Ô 2 của ticket 18 (một UDP chuyển tiếp **đã tăng tốc** vượt giới hạn UDP)
  không còn bị chặn bởi ticket `22`. Lưu ý khi viết mục `ddos-accel`: giới
  hạn UDP chỉ áp cho luồng **chưa có chiều trả lời**, nên một luồng UDP đã có
  chiều trả lời vượt giới hạn cả khi đi trên CPU lẫn khi đã tăng tốc. Xem
  `README.md` ("ddos_protect and the dashboard") và bmcwebUI ticket `02`.

## Traffic giữa hai cổng br-lan, và luật chặn theo máy (`bridge`, `bridge-block`, `block`) — ticket 19, 25

Traffic giữa hai cổng của `br-lan` được tăng tốc như traffic route: theo từng
kết nối, từ bảng conntrack (quyết định 2026-10-10). Daemon vẫn chạy với `-B`,
để hai máy không bị nối trong phần cứng theo cặp địa chỉ MAC.

Vì kết nối đã tăng tốc không còn đi qua luật của macfilter và client_control,
mỗi khi một trong hai tính năng đó bắt đầu chặn một máy, `bmchwaccel sweep`
xoá các entry conntrack của máy đó; kết nối rời phần cứng và gói tiếp theo gặp
luật. Hai script của web UI gọi nó sau khi áp luật, và cron gọi mỗi phút (cho
luật theo giờ của client_control). Cùng lệnh đó rút kết nối tới dịch vụ bị
chặn của bmcfirewall (`BMC_SVC4`/`BMC_SVC6`) và kết nối của máy đã hết phiên
đăng nhập bmcfido (`BMC_FIDO`); hai tính năng này chỉ có cron gọi. Chi tiết ở
`README.md`, "Machines and destinations that a feature blocks on every
packet".

Bốn mục:

| Mục | Đấu dây | Đo gì | Đạt khi |
|---|---|---|---|
| `bridge` | E | `iperf3 -P 4` từ PC1 tới PC2 qua `br-lan` | ≥ `MIN_MBPS`, gói không lên CPU, phần cứng có kết nối tới PC2 |
| `bridge-block` | E | luồng UDP tới `iperf3 -s -p 5202` của PC2, rồi lần lượt bốn tính năng chặn nó: macfilter, client_control, blocked services, bmcfido | sau khi có luật, dưới `MAX_CPU_PKTS` gói ra cổng của PC2 trong `WINDOW` giây |
| `bridge-neigh` | E | xoá neighbour của PC2 trên board, chạy luồng TCP tới `iperf3 -s` của PC2, rồi chạy `bmchwaccel sweep` | trước sweep luồng nằm trên CPU; sau sweep board có neighbour của PC2 và luồng, vẫn đang chạy, nằm trong phần cứng |
| `block` | A | như `bridge-block`, với PC2 ở phía wan | như trên, đếm ở cổng wan |

Với macfilter và client_control, luật được đặt bằng chính script mà web UI
gọi (`macfilter.sh add`, `client_control.sh set`), nên mục kiểm cả việc script
đó gọi `sweep`. Hai tính năng còn lại không đặt qua giao diện của chúng:

- blocked services: mục cho địa chỉ của PC2 vào ipset của dịch vụ đầu tiên
  trong `/etc/ipset.conf` (chỗ DNS vẫn điền) và thêm vào `BMC_SVC4` hai luật
  đúng dạng bmcfirewall ghi cho một dịch vụ bị chặn với mọi máy;
- bmcfido: mục cho bmcfido dựng luật của chính nó (`bmcfido reload_rules`,
  security mode là `fido` chỉ trong lệnh đó), cho hai PC vào set các máy đã
  đăng nhập, rồi rút PC1 ra khỏi set như khi hết hạn.

Với hai tính năng này mục tự chạy `bmchwaccel sweep`, như cron vẫn làm mỗi
phút. Điều được kiểm là `sweep` đọc được luật của chúng và rút luồng khỏi
phần cứng; đường từ giao diện tới luật thì không. Mục gỡ hết những gì nó đặt. Luồng
phải đang nằm trong phần cứng trước khi có luật; nếu nó đang ở trên CPU thì mục
báo `nothing shown` và FAIL, vì khi đó gói nào cũng gặp luật và không có gì
được chứng minh. Mỗi luồng có một dòng bắt đầu bằng `|`: số gói của cổng PC1
lên CPU và số gói ra cổng đích trước khi có luật, số gói ra cổng đích khi có
luật, và số gói mà luật đếm được. Script gỡ luật của nó khi xong; macfilter
được để ở trạng thái tắt.

Đấu dây E, không cần máy Linux:

```
PC1 192.168.5.10 ── eth1 [br-lan 192.168.5.1] LS1046 [br-lan] eth2 ── PC2 192.168.5.20
chạy script                                                            chạy "iperf3 -s" và "iperf3 -s -p 5202"
```

Tức là rút dây của PC2 khỏi `eth0` (wan), cắm sang một cổng `br-lan` khác
cổng của PC1 (ví dụ `eth2`), và đổi địa chỉ của PC2 sang mạng của `br-lan`:

```
# PC2 chạy macOS (en0 là cổng Ethernet nối vào board)
sudo ifconfig en0 inet 192.168.5.20 netmask 255.255.255.0
# PC2 chạy Linux
sudo ip addr flush dev eth0 && sudo ip addr add 192.168.5.20/24 dev eth0
# trên PC2, hai cửa sổ
iperf3 -s
iperf3 -s -p 5202
```

PC2 dùng địa chỉ khác thì đặt `BRIDGE_SERVER=<địa chỉ>` khi chạy script. Từ
PC1 thử `ping 192.168.5.20` trước. Board ở security mode `nac` hay `fido` sẽ
được script chuyển sang `off` trong lúc chạy rồi trả lại.

```
mkdir -p logs
sh scripts/hwaccel/acceptance.sh boot bridge bridge-block bridge-neigh 2>&1 | tee logs/t25-bridge.log
```

Với đấu dây A (PC2 ở `eth0`, 192.168.2.10):

```
sh scripts/hwaccel/acceptance.sh boot block 2>&1 | tee logs/t25-block.log
```

Mỗi mục `*-block` mất khoảng một phút rưỡi. Xong đấu dây E thì cắm PC2 lại vào
`eth0` và trả địa chỉ 192.168.2.10 cho nó.

Chưa có mục cho: luật client_control bắt đầu theo giờ (đã đo tay, ticket 25),
và macfilter ở mode whitelist.

## IPsec qua trang VPN — ticket 24

Dành cho image có strongSwan (từ commit "strongSwan in the image"). Đấu dây
A. **PC2 phải chạy Linux** (Ubuntu/Debian) vì nó là đầu bên kia của tunnel
và chạy strongSwan. Không mục nào của `acceptance.sh` phủ phần này: các bước
làm bằng tay, mỗi bước ghi một file dưới `logs/`.

Chưa có bước nào ở đây được chạy trên board. `tests/qemu-test.sh` dựng cùng
tunnel này bằng cùng script, với kernel làm IPsec. Điều bài này phải cho
thấy là thứ QEMU không cho thấy được: khi daemon tăng tốc đang chạy, ASK có
đưa khoá (SA) và các kết nối đi qua tunnel xuống phần cứng không, tunnel có
còn đúng không, và nhanh tới đâu.

```
PC1 192.168.5.10 ── eth1 [br-lan 192.168.5.1]  LS1046  [wan 192.168.2.1] eth0 ── PC2 192.168.2.10
                                                    └──── tunnel IPsec ────┘      mạng "bên kia": 10.98.0.0/24 (trên lo của PC2)
```

Mạng bên kia là 10.98.0.0/24, không phải 10.99.0.0/24: PPPoE server của đấu
dây A đã dùng 10.99.0.1 và 10.99.0.2.

### Chuẩn bị PC2 (Linux)

```
sudo apt install strongswan iperf3
sudo ip addr add 10.98.0.1/24 dev lo
sudo tee /etc/ipsec.conf <<'EOF'
config setup

conn hwaccel
    auto=add
    keyexchange=ikev2
    ike=aes256-sha256-modp2048!
    esp=aes256-sha256!
    left=192.168.2.10
    leftid=@hwaccel-192.168.2.10
    leftsubnet=10.98.0.0/24
    leftauth=psk
    right=192.168.2.1
    rightid=@hwaccel-192.168.2.1
    rightsubnet=192.168.5.0/24
    rightauth=psk
    type=tunnel
    forceencaps=yes
EOF
echo '@hwaccel-192.168.2.1 @hwaccel-192.168.2.10 : PSK "hwaccel-test-key"' | sudo tee /etc/ipsec.secrets
sudo ipsec restart
iperf3 -s -D                              # nếu chưa chạy
iperf3 -s -B 10.98.0.1 -p 5203 -D         # cho luồng UDP: phải gắn vào đúng địa chỉ đích
```

`leftid`/`rightid` phải đúng như trên: script của trang VPN đặt tên hai đầu
là `@<tên tunnel>-<địa chỉ>`, và tunnel ở đây tên `hwaccel`. Firewall của
PC2 (ufw), nếu bật, phải cho UDP 500, UDP 4500 và iperf3 vào.

### Chuẩn bị PC1

```
mkdir -p logs
sudo route -n add 10.98.0.0/24 192.168.5.1            # macOS
sudo ip route add 10.98.0.0/24 via 192.168.5.1        # Linux
```

Và một hàm đọc trạng thái của board, dùng ở mọi bước dưới đây (dán vào cửa
sổ lệnh của PC1, trong thư mục gốc của cây `hw-accel`):

```
t24() { ssh root@192.168.5.1 '
  echo "== $(date) uptime $(cut -d" " -f1 /proc/uptime) =="
  echo "-- bmchwaccel"; bmchwaccel status
  echo "-- ipsec status"; ipsec status
  echo "-- xfrm state"; ip -s xfrm state
  echo "-- cmm query sa"; cmm -c "query sa" 2>&1
  echo "-- cmm query secfailstats"; cmm -c "query secfailstats" 2>&1
  echo "-- cmm connections"; cmm -c "query connections" 2>&1 | tail -30
  echo "-- conntrack 10.98"; conntrack -L 2>/dev/null | grep "10\.98\." | head -8
  echo "-- nat rules of the VPN script"; iptables -t nat -S zone_wan_postrouting | grep -e "pol ipsec" ; iptables -S zone_wan_input | grep -e "p esp" -e 4500 -e "dport 500"
  echo "-- cpu"; top -b -n 1 | sed -n 1,4p
  echo "-- charon restarts: $( { /usr/libexec/logread-ubox 2>/dev/null; logread 2>/dev/null; } | grep -c "too long to start")"
  echo "-- kernel"; dmesg | tail -15
'; }
```

### Bước 0: board về trạng thái đo được

Thẻ mới khởi động ở security mode nac và `wan` chờ DHCP, mà PC2 không phải
DHCP server. Cho `wan` địa chỉ cố định và tắt portal, giữ bản gốc để trả lại
ở bước cuối:

```
ssh root@192.168.5.1 '
  [ -e /etc/t24-network.orig ] || cp /etc/config/network /etc/t24-network.orig
  [ -e /etc/t24-mode.orig ] || uci -q get system.@system[0].security_mode > /etc/t24-mode.orig
  uci set network.wan.proto=static; uci set network.wan.ipaddr=192.168.2.1; uci set network.wan.netmask=255.255.255.0
  uci commit network; /etc/init.d/network reload
  BMC_ADMIN_IP=192.168.5.10 bash /etc/bmcweb/backend/scripts/firewall/bmcfido.sh set mode off
' 2>&1 | tee logs/t24-0-prep.log
sh scripts/hwaccel/acceptance.sh boot brlan-wan 2>&1 | tee -a logs/t24-0-prep.log
t24 2>&1 | tee logs/t24-0-state.log
```

`brlan-wan` phải PASS trước khi đi tiếp: nếu traffic thường còn chưa được
tăng tốc thì các số đo IPsec không nói lên gì. Trong `t24-0-state.log`,
`charon restarts` phải là 0 (xem "IPsec" trong `README.md` về plugin
`af-alg`).

### Bước 1: dựng tunnel

Bằng trang VPN của web UI (tên `hwaccel`, local 192.168.2.1 với mạng
192.168.5.0/24, remote 192.168.2.10 với mạng 10.98.0.0/24, khoá
`hwaccel-test-key`), hoặc bằng chính script mà trang đó gọi:

```
ssh root@192.168.5.1 'bash /etc/bmcweb/backend/scripts/network/vpn_handle.sh set hwaccel 192.168.2.1 192.168.5.0/24 192.168.2.10 10.98.0.0/24 hwaccel-test-key' 2>&1 | tee logs/t24-1-set.log
sleep 10
ping -c 5 10.98.0.1 2>&1 | tee -a logs/t24-1-set.log
t24 2>&1 | tee logs/t24-1-state.log
```

Chờ đợi: `ipsec status` có `hwaccel[..]: ESTABLISHED` và
`hwaccel{..}: INSTALLED, TUNNEL`, năm ping đều có trả lời, `xfrm state` có
hai SA với số gói khác 0. `cmm query sa` cho biết daemon đã nhận SA hay
chưa.

### Bước 2: đo với Tăng tốc phần cứng bật

Mỗi lần đo 20 giây; giây thứ 8 hàm `t24` chụp trạng thái trong lúc iperf3
đang chạy.

```
( sleep 8; t24 > logs/t24-2-tcp-up-state.log 2>&1 ) &
iperf3 -c 10.98.0.1 -P 4 -t 20 2>&1 | tee logs/t24-2-tcp-up.log; wait

( sleep 8; t24 > logs/t24-2-tcp-down-state.log 2>&1 ) &
iperf3 -c 10.98.0.1 -P 4 -t 20 -R 2>&1 | tee logs/t24-2-tcp-down.log; wait

( sleep 8; t24 > logs/t24-2-udp-state.log 2>&1 ) &
iperf3 -c 10.98.0.1 -p 5203 -u -b 800M -l 1300 -t 20 2>&1 | tee logs/t24-2-udp.log; wait
```

### Bước 3: cùng các lần đo với Tăng tốc phần cứng tắt

Đây là con số trên CPU để so sánh.

```
ssh root@192.168.5.1 'bmchwaccel disable' 2>&1 | tee logs/t24-3-disable.log
sleep 5; ping -c 3 10.98.0.1 2>&1 | tee -a logs/t24-3-disable.log

( sleep 8; t24 > logs/t24-3-tcp-up-state.log 2>&1 ) &
iperf3 -c 10.98.0.1 -P 4 -t 20 2>&1 | tee logs/t24-3-tcp-up.log; wait

( sleep 8; t24 > logs/t24-3-tcp-down-state.log 2>&1 ) &
iperf3 -c 10.98.0.1 -P 4 -t 20 -R 2>&1 | tee logs/t24-3-tcp-down.log; wait

iperf3 -c 10.98.0.1 -p 5203 -u -b 800M -l 1300 -t 20 2>&1 | tee logs/t24-3-udp.log

ssh root@192.168.5.1 'bmchwaccel enable' 2>&1 | tee logs/t24-3-enable.log
sleep 5; ping -c 3 10.98.0.1 2>&1 | tee -a logs/t24-3-enable.log
iperf3 -c 10.98.0.1 -P 4 -t 20 2>&1 | tee logs/t24-3-tcp-up-again.log
```

Tunnel phải sống qua cả lần tắt lẫn lần bật: ba ping sau mỗi lệnh phải có
trả lời mà không phải dựng lại tunnel.

### Bước 4: đổi khoá trong lúc có traffic

Trên PC2, cho SA của tunnel sống ngắn rồi nạp lại: thêm ba dòng vào `conn
hwaccel` trong `/etc/ipsec.conf` và chạy `sudo ipsec restart`.

```
    lifetime=60s
    margintime=20s
    rekeyfuzz=0%
```

`ipsec restart` trên PC2 làm tunnel rớt, và board có thể không tự dựng lại:
chạy lại lệnh `vpn_handle.sh set` của bước 1 rồi chờ 10 giây. Sau đó trên
PC1, hai phút traffic, tức khoảng ba lần đổi khoá:

```
ping -c 3 10.98.0.1 2>&1 | tee logs/t24-4-rekey.log
( sleep 60; t24 > logs/t24-4-rekey-state.log 2>&1 ) &
iperf3 -c 10.98.0.1 -P 4 -t 120 2>&1 | tee -a logs/t24-4-rekey.log; wait
t24 2>&1 | tee logs/t24-4-rekey-after.log
```

Xong thì bỏ ba dòng đó khỏi `/etc/ipsec.conf` của PC2 và `sudo ipsec
restart`.

### Bước 5: firewall restart và reboot khi tunnel đang lên

Các luật iptables mà script của trang VPN thêm (cho IKE và ESP vào từ wan,
và luật miễn NAT cho gói đi vào tunnel) không nằm trong cấu hình firewall.
Bước này xem chúng có mất không, và gói của PC1 khi đó đi đâu.

```
ssh root@192.168.5.1 '/etc/init.d/firewall restart' >/dev/null 2>&1; sleep 8
ping -c 5 10.98.0.1 2>&1 | tee logs/t24-5-fw-restart.log
t24 2>&1 | tee -a logs/t24-5-fw-restart.log

ssh root@192.168.5.1 reboot; sleep 150
ping -c 5 10.98.0.1 2>&1 | tee logs/t24-5-reboot.log
t24 2>&1 | tee -a logs/t24-5-reboot.log
```

Trên PC2, trong lúc PC1 ping ở mỗi lần, xem gói tới có được mã hoá không
(UDP port 4500) hay tới dưới dạng ICMP trần từ 192.168.2.1:

```
sudo tcpdump -ni <nic> -c 20 'host 192.168.2.1 and (udp port 4500 or icmp)'
```

Ghi lại điều thấy được (mã hoá / ICMP trần / không có gì) vào ticket: file
log của PC1 không chứa phần này.

### Bước 6: trả board về như cũ

```
ssh root@192.168.5.1 '
  bash /etc/bmcweb/backend/scripts/network/vpn_handle.sh del hwaccel
  cp /etc/t24-network.orig /etc/config/network && rm /etc/t24-network.orig; /etc/init.d/network reload
  m=$(cat /etc/t24-mode.orig); rm -f /etc/t24-mode.orig
  [ -z "$m" ] || BMC_ADMIN_IP=192.168.5.10 bash /etc/bmcweb/backend/scripts/firewall/bmcfido.sh set mode "$m"
' 2>&1 | tee logs/t24-6-restore.log
sudo route -n delete 10.98.0.0/24            # macOS; Linux: sudo ip route del 10.98.0.0/24
```

Trên PC2: `sudo ipsec stop; sudo ip addr del 10.98.0.1/24 dev lo`.

### Đọc kết quả

| Câu hỏi | Đọc ở đâu |
|---|---|
| Tunnel có lên cạnh daemon đang chạy không | `t24-1-set.log`, `t24-1-state.log` |
| SA có vào phần cứng không | `cmm query sa` trong các file `*-state.log` |
| Kết nối qua tunnel có được tăng tốc không | `accelerated` của `bmchwaccel status`, `cmm connections` và dòng CPU trong `t24-2-*-state.log`, so với `t24-3-*-state.log` |
| Nhanh tới đâu | Mbps của `t24-2-*.log` (bật) so với `t24-3-*.log` (tắt) |
| Phần cứng có lỗi mã hoá không | `cmm query secfailstats`, và các dòng kernel cuối mỗi file state |
| Đổi khoá có làm đứt không | `t24-4-rekey.log`: giây nào về 0 Mbps, có `error` không |
| Firewall restart, reboot | `t24-5-*.log`, cùng điều thấy ở `tcpdump` trên PC2 |

Chưa có ngưỡng đạt hay không đạt: đây là lần đo đầu tiên, và ticket 24
dùng các con số này để quyết định `forceencaps`, thuật toán và bản ASK.

## Lần nghiệm thu Mốc A1 (ticket 11)

Một board, các cổng 1G, image của nhánh `hw-accel` với microcode ASK. PC2
chạy Linux hoặc macOS, không dùng Windows. Giữ kết quả của từng bước dưới
`logs/` và dán vào ticket.

| Tiêu chí của ticket | Bước |
|---|---|
| Route và NAT `br-lan` → `wan`: 900 Mbps, gói không qua CPU | 1 (`brlan-wan`, `brlan-wan-back`) |
| Như trên, từ một VLAN và qua wan PPPoE | 1 (`vlan-wan*`, `pppoe*`) |
| Tắt trong lúc iperf3 chạy, bật lại | 1 (`toggle`), 2 |
| Thẻ có microcode 106.x | 5 |
| Một giờ traffic | 3 |
| 20 lần boot liên tiếp | 4 |
| Các vấn đề còn mở của bản port ASK, và đã gặp cái nào | danh sách nằm trong ticket; ghi lại những gì thấy ở bất kỳ bước nào |

1. Đấu dây A, PC1 có interface VLAN và PC2 có cả hai iperf3 server cùng
   PPPoE server (các phần ở trên). Mọi mục mặc định, khoảng 5 phút:

   ```
   mkdir -p logs
   sh scripts/hwaccel/acceptance.sh 2>&1 | tee logs/a1-default.log
   ```

2. `sh scripts/hwaccel/acceptance.sh toggle-back 2>&1 | tee logs/a1-toggle-back.log`
3. `soak`, như ở trên.
4. `reboots`, như ở trên.
5. Cuối cùng, vì phải ghi mới thẻ cho nó và ghi thêm lần nữa sau nó:
   `ucode-public`, như ở trên. Thẻ ghi mới trở về 192.168.5.1 ("br-lan ở
   192.168.5.0/24").

Bất cứ điều gì board làm mà không mục nào bắt được (một dòng trên console
serial, một cổng mất link, một con số trông sai) cũng đưa vào ticket, kèm
bước mà nó được thấy.

## Đọc một kết quả FAIL

- `soak`, `second N: ...`: điều một mục traffic sẽ nói, cho lần đọc board
  bắt đầu ở giây N của lần chạy.
- `soak`, `the last minute carried N Mbps, the first M Mbps`: dòng có Mbps
  của từng phút cho thấy tốc độ tụt một lần hay tụt dần. So bộ nhớ ở hai
  đầu và chạy `brlan-wan` sau đó: board chậm luôn từ đó là một phát hiện,
  một phút chậm đơn lẻ thì chỉ về phía các PC (ticket 08).
- `soak`, `the daemon process was N at the start and is M now`: daemon đã
  chết và được khởi động lại; `logread | grep -E 'cmm|bmcHwAccel'` và
  console serial nói thêm.
- `soak`, `no longer has the mark of the start`: log bị ghi đè trong lúc
  chạy, nên không chấm được các dòng của nó. Có gì đó đã làm đầy log: xem
  `dmesg | tail -50` hoặc `logread | tail -50` trên board.
- `soak`, `iperf3: no report`: iperf3 trên PC1 kết thúc mà không có kết quả.
  PC1 đã ngủ, hoặc iperf3 server trên PC2 bận hay đã tắt.
- `reboots`, `stopped in boot N, which could not be measured`: iperf3 không
  cho kết quả ở lần boot đó; các lý do phía trên nói bản thân lần boot trông
  thế nào. Kiểm tra iperf3 server trên PC2 và chạy lại mục.
- `reboots`, `boot N did not come up`: board không trả lời qua ssh với một
  lần boot mới trong 300 s. Console serial cho biết nó đang đứng ở đâu.
- `no PPPoE session on wan`: PPPoE server không chạy hoặc không nằm trên dây
  tới `eth0`. Trên board: `logread | grep pppd`.
- `N accelerated connection(s) ... do not come from 192.168.30.10`: PC1 gửi
  các mục VLAN qua địa chỉ không tag; thiếu route cho 192.168.30.10.
- `0 accelerated`, hoặc bộ đếm per-CPU tăng hàng trăm nghìn: traffic chạy
  trên CPU. Dưới mục như vậy script in những gì `cmm` biết về các VLAN và
  phiên PPPoE, một entry conntrack của traffic và phần cuối log của `cmm`.
  Đưa cả kết quả vào ticket; một bố cục không tăng tốc được là quyết định
  của con người, không phải thứ để lách trong script.
- `bmchwaccel status says unavailable, need on`: `bmchwaccel status` trên
  board cho lý do (README, "Unavailable"). `bmchwaccel --dry-run apply`
  liệt kê cái đang thiếu, `bmchwaccel apply` thử lại, `logread | grep -E
  'cmm|bmcHwAccel'` và `dmesg | grep -i cdx` nói vì sao. Đưa kết quả vào
  ticket.
- `bmchwaccel status says off, need on`: Tăng tốc phần cứng đang tắt
  (`bmchwaccel get`); chạy `bmchwaccel enable`.
- `boot`, `the daemon was started N times, need 1`: daemon chết sau khi lần
  boot khởi động nó và được khởi động lại. `logread | grep -E
  'cmm|bmcHwAccel'` và console serial (daemon in lỗi ra đó, không ra syslog)
  nói thêm. Đưa cả hai vào ticket.
- `bmchwaccel status counts 0 accelerated connections while iperf3 runs` đi
  cùng `5 accelerated, 5 masqueraded`: phần cứng có các kết nối nhưng con
  số CLI đọc từ daemon sai. Trên board, trong lúc iperf3 chạy:
  `cmm -c 'show stat connection query'`. Đưa kết quả vào ticket.
- `toggle`, `disabled: N rx packets reached the CPU ...: the hardware still
  forwards the traffic, or the TCP sessions stopped`: xem `iperf3 over both
  switches` trong cùng dòng. Giây chậm nhất 0 Mbps với status `off` nghĩa
  là các phiên đứt khi quay về CPU; trên board,
  `sysctl net.netfilter.nf_conntrack_tcp_be_liberal` phải ra 1 sau
  `bmchwaccel disable`. Lần chạy đủ tốc độ với status `off` nghĩa là daemon
  đã thoát mà không dọn phần cứng: image có được build với
  `package/ask/cmm/patches` không?
- `toggle`, `disabled: N rx packets reached the CPU, but iperf3 carried M
  Mbps`: một phần traffic không đi qua CPU trong lúc status báo `off`. Dòng
  Mbps cho thấy tốc độ có tụt hay không.
- `toggle`, `enabled again: N Mbps from second S of iperf3 to its end`: dòng
  Mbps cho thấy các phiên đứng yên, hồi lại chậm, hay chậm từ đầu (so với
  một lần `brlan-wan` trước và sau). Đưa các dòng script in dưới mục vào
  ticket.
- `boot-time`, `the PHY firmware upload failed`: MDIO không chuyển được
  firmware ở tần số ghi trong phần `MDC` của dòng. Giảm `clock-frequency`
  của `mdio@fd000` trong `fsl-ls1046a-rdb-ask.dts`, hoặc bỏ nó để quay về
  mức U-Boot để lại, rồi build lại.
- `boot-time`, `the kernel did not set the MDC frequency`: kernel log có một
  cảnh báo `fsl-fman_xmdio` nói vì sao (`dmesg | grep xmdio`); cổng vẫn chạy,
  việc nạp chậm như trước.
- `off-boot`, `N ASK module(s) loaded in a boot with hardware acceleration
  disabled`: có thứ khác ngoài `bmcHwAccel` nạp chúng; `ls /etc/modules.d`
  và `ls /etc/rc.d | grep -i cmm` trên board.
- `pppoe-drop`, `N packets left eth0 while the session was down`: phần cứng
  vẫn chuyển tiếp vào một phiên không còn tồn tại.
- `mwan-lost`, `N packets left eth2 (wan2) ... connections still flow into
  the WAN that is Mất Internet`: phần cứng vẫn giữ kết nối sau Chuyển WAN.
  Các dòng `wait`/`window` dưới kết quả cho thấy, từng giây, số gói đã rời
  hai cổng WAN. Đưa cả kết quả cùng `logread | grep bmcMultiWAN` vào ticket.
- `mwan-lost`, `the UDP flow was not accelerated before wan2 lost Internet`:
  luồng UDP chưa hề chạy. Server thứ ba trên các ISP phải được gắn vào địa
  chỉ đích (`iperf3 -s -B 198.51.100.2 -p 5203`), và có thể còn bận tới 2
  phút sau lần chạy trước.
- `ospf-withdrawn`, `N packets left eth2 ... the hardware still sends the
  connection through the Link định tuyến of the route that is gone`: phần
  cứng vẫn giữ đường cũ sau khi OSPF rút route. Đưa cả kết quả cùng
  `cmm -c 'query connections'` và `ip -4 route show` của board vào ticket.
- `ospf-moved`, `after: N packets left eth2 ... the traffic leaves through
  the Link định tuyến on eth2`: route đã sang `eth4` nhưng phần cứng vẫn gửi
  qua `eth2`. `after: ... rx packets reached the CPU`: kết nối đi đúng đường
  mới nhưng không được tăng tốc lại. Đưa kết quả và dòng `Mbps each second`
  vào ticket.
- `ospf`, `no OSPF neighbour on eth2`: trên router láng giềng xem
  `sudo vtysh -c 'show ip ospf neighbor'` và `sudo tcpdump -ni <nicA> proto 89`
  (phải thấy hello của cả hai phía, 10 s một lần). Thường là thiếu
  `ip ospf network point-to-point`, firewall của máy đó chặn giao thức 89,
  hoặc máy ảo không ở chế độ bridged.
- `mwan`, `wan2 (...) is "down unknown"`: PC của ISP B không cắm vào `eth2`,
  chưa có 192.168.3.10, hoặc không trả lời ping của board.
- `mac-temp`, `no port uses a temporary MAC`: U-Boot vẫn truyền địa chỉ.
  Thứ kernel nhận được cho cổng wan:
  `hexdump -C /sys/firmware/devicetree/base/soc/fman@1a00000/ethernet@e4000/local-mac-address`.
- `mac-temp`, `random, changes at every boot`: kernel không đọc được ID duy
  nhất từ fuse (toàn 0 hoặc toàn 1, hoặc không có node `fsl,ls1021a-sfp`
  trong device tree). Tám byte nó đọc nằm ở offset 28 của thiết bị fuse:
  `hexdump -C -s 28 -n 8 /sys/bus/nvmem/devices/*/nvmem`. Đưa kết quả vào
  ticket.
- `sysupgrade`, `sysupgrade -T does not accept the image`: các dòng bên dưới
  là những gì board đã nói. `(2.0->3.0)` nghĩa là thẻ được ghi trước khi
  phiên bản image được nâng; ghi lại thẻ.
- `sysupgrade`, `the board did not come back from a new boot`: nếu board vẫn
  đang chạy lần boot cũ, các dòng bên dưới là những gì `sysupgrade` in ra
  (`/tmp/hwaccel-sysupgrade.log` trên board). Nếu nó không trả lời gì, xem
  console serial; có thể phải ghi lại thẻ.
- `sysupgrade`, `the configuration was not kept` hoặc `a file outside the
  configuration is still there`: trên console serial `sysupgrade` in
  `Writing kernel...`, `Writing rootfs...` và `Saving config backup...`
  trước khi reboot; đưa phần đó của console vào ticket.
- `sysupgrade-old`, `sysupgrade -T accepted the image`: firmware 24.10 sẽ
  cài một firmware không tăng tốc được. Đưa kết quả của
  `uci get system.@system[0].compat_version` trên board vào ticket.
