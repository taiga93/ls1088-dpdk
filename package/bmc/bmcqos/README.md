# bmcqos (firewall3)

`bmcqos` kết hợp phân loại lưu lượng bằng firewall3/iptables với shaping bằng
`tc`. Cấu hình UCI nằm tại `/etc/config/bmcqos`.

## Kiến trúc

1. `/etc/init.d/bmcqos` đọc UCI và chạy `/etc/bmcqos/bmcqos.sh`.
2. `/usr/lib/bmcqos/firewall.sh` tạo các chain mangle riêng
   `BMCQOS_PRE`, `BMCQOS_CLASSIFY` và `BMCQOS_CONNMARK` cho IPv4/IPv6.
3. Rule gán DSCP cho chiều LAN -> WAN và lưu DSCP vào 8 bit thấp của
   conntrack mark.
4. `tc-ctinfo` phục hồi DSCP khi redirect ingress từ WAN sang `ifb-WAN`.
5. CAKE đọc DSCP trực tiếp; HFSC/HTB/Hybrid dùng tc filter để ánh xạ DSCP vào
   class tương ứng.
6. fw3 gọi `/usr/share/bmcqos/firewall.include` sau mỗi lần reload để dựng lại
   các chain do bmcqos sở hữu.

Backend không flush toàn bộ bảng `mangle`; khi stop/reload, nó chỉ xóa jump và
các chain có prefix cố định `BMCQOS_`.

## Nhóm tính năng

- Shaping upload/download: CAKE, HFSC, HTB và Hybrid.
- IFB + ctinfo cho download shaping.
- Autorate tùy chọn.
- Rule DSCP tĩnh theo protocol, IP/CIDR, ipset và port.
- Nhóm mặc định realtime, video conference và bulk.
- Static ipset cho IPv4/IPv6.
- UCI, procd, hotplug và status.

Các tính năng phụ thuộc đặc tính nftables đã được tắt: dynamic IP set,
auto-merge IP range, meter/set statistics, per-device rate limit, connection
flow detection, ACK regulation theo connection, TCP initial/sustained
down-priority, inline/raw nft rule và nft trace.

Software flow offloading nên được tắt để mọi packet đi qua classifier fw3.

## Giới hạn với Multi-WAN

`bmcqos` chỉ shape **một WAN**: thiết bị trong `settings.WAN` (CAKE/HFSC/HTB
trên egress của nó và `ifb-<WAN>` cho ingress). Khi bật Multi-WAN
(`bmcMultiWAN`), traffic mà Luật chọn WAN hay Chuyển WAN đưa sang WAN khác
(`wan2`, ...) không bị shape và không qua `BMCQOS_PRE` (chain chỉ khớp
`-o <WAN>`). QoS trên nhiều WAN là việc riêng của `bmcqos`, chưa làm.

Hai gói dùng chung conntrack mark mà không đè nhau: `bmcqos` giữ 8 bit thấp
(`0xff`, DSCP), mwan3 giữ `0x3F00` (WAN đã chọn). Chain `BMCQOS_*` nằm trong
mangle `FORWARD`, còn `mwan3_hook` nằm trong mangle `PREROUTING`/`OUTPUT`.

## Với Tăng tốc phần cứng (LS1046, nền 25.12)

Một Kết nối đã tăng tốc không đi qua qdisc và IFB, nên giới hạn của `bmcqos`
không còn tác dụng với nó. Vì vậy khi `bmcqos` bật, init script đăng ký WAN đang
shape với `bmcHwAccel` (`bmchwaccel keep bmcqos wan <WAN>`): mọi kết nối qua WAN
đó chạy trên CPU, traffic khác vẫn được tăng tốc (ADR-0011). Tắt `bmcqos` thì
gỡ (`bmchwaccel release bmcqos`); đổi `settings.WAN` rồi restart thì phạm vi đổi
theo. `bmchwaccel status` liệt kê trong `on_cpu`.

Hệ quả: WAN có `bmcqos` không vượt được tốc độ chuyển tiếp của CPU. Trên board
không có `bmcHwAccel`, init script bỏ qua bước này.

Trên nền này cấu hình mặc định là `enabled '0'`, `WAN 'eth0'` (cổng `wan` của
LS1046). Bản 24.10 để `enabled '1'` trên `eth1`, mà ở nền mới `eth1` là một
cổng của `br-lan`.

## Ví dụ UCI

```uci
config ipset 'gaming_devices'
	option enabled '1'
	option family 'ipv4'
	list ip4 '192.168.1.100'
	list ip4 '192.168.1.101/32'

config rule 'gaming'
	option enabled '1'
	option family 'ipv4'
	option proto 'udp'
	option src_ip '@gaming_devices'
	option dest_port '3074,30000-65535'
	option class 'cs5'
```

Static ipset chỉ nhận địa chỉ hoặc CIDR. Dải `start-end` và ipset động không
được backend fw3 hỗ trợ.
