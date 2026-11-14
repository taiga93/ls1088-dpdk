# Build firmware `hw-accel` từ một bản clone mới

Hướng dẫn cho người vừa clone repo về máy mình và muốn ra được image thẻ SD
cho LS1046A-RDB có Tăng tốc phần cứng (NXP ASK). `README.md` cùng thư mục mô
tả firmware; file này chỉ nói về việc build.

**Điều cần biết trước:** các bước dưới đây mô tả đúng cách máy build của
nhánh này đang làm (container Ubuntu 20.04 trên máy arm64, build bằng
root). Một lần build từ bản clone hoàn toàn mới, và một lần build trên máy
x86-64, **chưa được thử**. Gặp chỗ nào khác với mô tả thì xem mục "Lỗi
thường gặp" ở cuối, và báo lại để sửa hướng dẫn.

## Tóm tắt

| | |
|---|---|
| Kết quả | `bin/targets/layerscape/armv8_64b/openwrt-layerscape-armv8_64b-fsl_ls1046a-rdb-sdboot-squashfs-sdcard.img.gz` |
| Lệnh | `HWACCEL_RELEASE=1 scripts/hwaccel/build.sh` |
| Ba thứ không có trong repo | web UI (`bmcwebUI`), microcode ASK, thư mục tải nguồn `dl` |
| Dung lượng | khoảng 11 GB cho lần build đầu, cộng khoảng 1,5 GB nguồn tải về |
| Thời gian | lần build đầu trọn vẹn chưa được đo; riêng Node.js cho router mất khoảng một giờ trên máy build của nhánh. Build lại sau khi sửa: khoảng 5 phút |

## 1. Máy build

- **Linux**, hệ thống file phân biệt chữ hoa chữ thường. Trên macOS phải
  build trong Docker với một ổ phân biệt hoa thường: clone cây OpenWrt lên
  ổ mặc định của macOS làm mất các file chỉ khác nhau ở chữ hoa.
- Các gói build của OpenWrt. Trên Ubuntu/Debian:

  ```
  sudo apt update
  sudo apt install build-essential clang flex bison g++ gawk gettext git \
      libncurses-dev libssl-dev python3 python3-setuptools rsync swig unzip \
      zlib1g-dev file wget curl
  ```

  Đây là danh sách chuẩn của OpenWrt; nó chưa được kiểm từng gói trên một
  máy sạch cho nhánh này. Máy build của nhánh có gcc 9.4 và Python 3.8.
- **Trên máy arm64:** thêm một bản Go có sẵn (`sudo apt install golang-go`,
  cho ra `/usr/lib/go`). Trình biên dịch Go mà `bmcfirewall` cần không tự
  dựng được bước đầu trên arm64. Bản Go ở chỗ khác thì chỉ bằng
  `GO_BOOTSTRAP_ROOT=<thư mục>`. Trên x86-64 không cần.
- **Mạng:** lần build tải nguồn từ `git.openwrt.org`, `github.com` (trong đó
  có nguồn ASK ở `github.com/we-are-mono/ASK`), các mirror nguồn của OpenWrt
  và kho npm (`bmcwebUI` gọi `npx esbuild` lúc build). Web UI nằm trên máy
  chủ nội bộ `192.168.2.37:9000`.
- Build bằng user thường hay bằng root đều được; `build.sh` tự đặt
  `FORCE_UNSAFE_CONFIGURE=1` cho trường hợp root.

Muốn build trong Docker như máy của nhánh: một container Ubuntu 20.04 với
thư mục làm việc được mount vào, ví dụ

```
docker run -dit --name ubuntu20 -v <thư mục làm việc>:/home/working ubuntu:20.04
docker exec -it ubuntu20 bash        # rồi cài các gói ở trên, không cần sudo
```

Hai dòng này là ví dụ, chưa được chạy đúng như vậy: container của nhánh
được dựng từ trước.

## 2. Lấy mã nguồn

```
git clone -b ls1046-hw-accel-ask git@github.com:nhatdevemb/bmcfirewall_ls1046.git bmcfirewall_ls1046-hw-accel
cd bmcfirewall_ls1046-hw-accel
```

Nhánh là `ls1046-hw-accel-ask` (trong tài liệu này gọi tắt là `hw-accel`): OpenWrt v25.12.5 cộng ASK. Đừng build từ `master` hay
nhánh khác bằng hướng dẫn này.

## 3. Ba thứ không có trong repo

### 3.1 Web UI

`bmcwebUI` có repo riêng. Build lấy đúng thứ đang được checkout trong
`package/bmc/bmcwebUI` và dừng nếu thư mục đó không có.

```
git clone -b dynamicRouting_p2 http://192.168.2.37:9000/bmc_firewall/bmcwebUI.git package/bmc/bmcwebUI
git -C package/bmc/bmcwebUI log --oneline -1
```

Dòng in ra phải là commit "fix(firewall): DHCPGuard keeps its ebtables rules
in a chain of its own" hoặc mới hơn. Cũ hơn thế thì các service firewall
trong image gọi lệnh mà script của web UI chưa có.

### 3.2 Microcode ASK

File `fman-ucode-ask-210.10.1.bin` (51652 byte) là của NXP, độc quyền, và
**không nằm trong repo nào**. Xin file từ đồng nghiệp qua kênh nội bộ rồi
đặt vào thư mục mà git bỏ qua, giữ nguyên tên:

```
mkdir -p package/firmware/layerscape/fman-ucode/local
cp <nơi lưu>/fman-ucode-ask-210.10.1.bin package/firmware/layerscape/fman-ucode/local/
sha256sum package/firmware/layerscape/fman-ucode/local/fman-ucode-ask-210.10.1.bin
```

Kết quả phải là

```
5f3ed8d32b8659aafd8912d5d9920306350cae7a85884d81859152b9723eff0d
```

Không commit file này, không dùng `git add -f` cho nó, không gửi ra ngoài:
`tests/ask-ucode-test.sh` báo lỗi khi git theo dõi nó. Thiếu file thì image
vẫn build được nhưng mang microcode công khai và **không tăng tốc**; xem
bước 4.

### 3.3 Thư mục tải nguồn

`build.sh` tìm `./dl`; không có thì nó tạo liên kết tới `../../dl-25.12` và
dừng nếu thư mục đó không tồn tại (thư mục ấy chỉ có trên máy build của
nhánh). Một thư mục trống là đủ, lần build sẽ tải nguồn vào đó:

```
mkdir dl logs
```

Đã có sẵn một bộ nguồn của OpenWrt 25.12 ở chỗ khác thì trỏ tới nó bằng
`DL_DIR_SHARED=<thư mục>` thay vì tạo `dl`.

## 4. Build

```
HWACCEL_RELEASE=1 scripts/hwaccel/build.sh > logs/hwaccel-build.log 2>&1
```

Chạy ở gốc cây (đường dẫn `logs/` trong lệnh là tương đối; bản thân `build.sh` chạy được từ thư mục nào cũng được). Trong Docker:

```
docker exec ubuntu20 sh -c 'HWACCEL_RELEASE=1 /home/working/bmcfirewall_ls1046-hw-accel/scripts/hwaccel/build.sh \
    > /home/working/bmcfirewall_ls1046-hw-accel/logs/hwaccel-build.log 2>&1'
```

Theo dõi bằng `tail -f logs/hwaccel-build.log`.

`HWACCEL_RELEASE=1` làm lần build dừng ngay khi thiếu microcode ASK hoặc
sha256 của nó sai. Không có biến đó, lần build đi tiếp với microcode công
khai và chỉ in cảnh báo ở cuối log; image như vậy khởi động và chuyển tiếp
bằng CPU, `bmchwaccel status` báo `unavailable` với lý do `microcode`.

Lệnh trên chạy ba giai đoạn theo thứ tự:

| Giai đoạn | Làm gì |
|---|---|
| `toolchain` | cập nhật và cài feed, ghi `.config` từ `config_LS1046ARDB`, build công cụ và toolchain |
| `image` | tải nguồn, build mọi gói và image thẻ SD |
| `check` | `check-image.sh`: đọc lại image, trong đó có microcode, và kiểm những thứ image phải có |

Trước giai đoạn đầu, script tự kiểm vài điều và dừng nếu sai: kernel đúng
6.12.94, không có file `feeds.conf`, các bản sao patch ASK khớp với bản
ghim, microcode dùng được.

Không sửa `.config` bằng tay: mỗi giai đoạn ghi lại `.config` từ file cấu
hình đầy đủ `config_LS1046ARDB` ở gốc repo. Muốn thêm gói thì đổi file đó:
`./bmc_build_prepare.sh LS1046ARDB`, `make menuconfig`, rồi
`./bmc_build_prepare.sh --save LS1046ARDB`. Lý do của các lựa chọn hiện có ở
`scripts/hwaccel/config.md`.

## 5. Kết quả

Lần build đạt khi log kết thúc bằng

```
check-image: PASS  bin/targets/layerscape/armv8_64b/openwrt-layerscape-armv8_64b-fsl_ls1046a-rdb-sdboot-squashfs-sdcard.img.gz
hwaccel-build: stage check done
hwaccel-build: all stages done (release build)
```

Một dòng `WARN` về microcode trong phần `check-image` nghĩa là image mang
microcode công khai: quay lại bước 3.2.

Ghi thẻ SD (thay `/dev/sdX` bằng **đúng** thiết bị của thẻ; lệnh này xoá
toàn bộ thiết bị được chỉ ra):

```
lsblk                                   # tìm thẻ
gunzip -c bin/targets/layerscape/armv8_64b/openwrt-layerscape-armv8_64b-fsl_ls1046a-rdb-sdboot-squashfs-sdcard.img.gz \
    | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
```

Phải ghi cả thẻ: microcode và U-Boot nằm trong image thẻ, `sysupgrade`
không ghi chúng. Một mạch đang chạy firmware 24.10 từ chối image này qua
`sysupgrade` và yêu cầu ghi lại thẻ.

Lần boot đầu của thẻ mới:

- `br-lan` ở 192.168.5.1/24 trên các cổng `eth1` tới `eth5`, `wan` là `eth0`.
- Web UI: `https://192.168.5.1:3737`. SSH: `ssh root@192.168.5.1`.
- Security mode là `nac` (captive portal): máy trong LAN chưa đăng nhập ở
  portal thì không ra được wan. Máy đặt địa chỉ cố định 192.168.5.x vẫn
  vào được chính mạch.
- Kiểm nhanh: `bmchwaccel status` phải có `"state":"on"`.

Bàn test và các bài đo nằm trong `bench.md`.

## 6. Build lại sau khi sửa

```
scripts/hwaccel/build.sh image check > logs/hwaccel-build.log 2>&1
```

Thêm `HWACCEL_RELEASE=1` cho image sẽ phát hành. Giai đoạn `toolchain` chỉ
cần chạy lại khi feed hoặc toolchain đổi.

- Sửa hoặc bỏ một patch kernel: chạy `make target/linux/clean` trước.
- Lấy web UI mới: `git -C package/bmc/bmcwebUI pull`, rồi build lại. Lần
  build ghi `server.bundle.js` và các file `.gz` vào chính thư mục đó, nên
  `git status` ở đó luôn báo vài file đã sửa; `git checkout -- .` trước khi
  `pull` nếu git từ chối.
- Lấy mã firmware mới: `git pull` ở gốc cây, rồi build lại.
- Không sửa `build.sh` trong lúc nó đang chạy.

## 7. Chạy test (không bắt buộc)

```
scripts/hwaccel/build.sh test > logs/hwaccel-test.log 2>&1
```

Khoảng một giờ. Cần `qemu-system-aarch64`, `dtc` (gói `device-tree-compiler`)
và `python3`, và vài cổng TCP trống (2222, 2223). Giai đoạn này chạy các
test của script, kiểm root filesystem đã build, rồi boot image trong QEMU ba
lần. Trong QEMU các module ASK không nạp được, nên các mục đo traffic ở đó
kết thúc `FAIL` có chủ ý; dòng quyết định là `qemu-test: PASS` ở cuối.

Không có cây firmware 24.10 đã build nằm cạnh (`../bmcfirewall_ls1046`, hoặc
`FW2410_ROOT`), test sysupgrade bỏ qua phép kiểm với firmware 24.10 và nói
rõ điều đó.

## Lỗi thường gặp

Chín dòng đầu là thông báo của chính `build.sh` và các script nó gọi. Ba
dòng cuối là những chỗ dễ hỏng trên một máy mới, suy từ cách lần build làm
việc; chúng chưa từng được gặp trên máy build của nhánh.

| Dòng trong log | Nguyên nhân | Cách xử lý |
|---|---|---|
| `the ASK microcode is not usable for a release build` | thiếu file microcode, hoặc sai sha256, khi có `HWACCEL_RELEASE=1` | bước 3.2; các dòng `ask-ucode:` phía trên nêu tên file, sha256 và nơi đã tìm |
| `ask-ucode: ERROR: ...: sha256 mismatch` | file không phải bản 210.10.1 | lấy lại đúng file |
| `ask-ucode: WARNING: no fman-ucode-ask-210.10.1.bin in: ...` | build thường, không có microcode | image sẽ không tăng tốc; bước 3.2 |
| `no web UI in package/bmc/bmcwebUI` | chưa clone web UI | bước 3.1 |
| `dl points to a missing directory` | không có `./dl` và không có `../../dl-25.12` | `mkdir dl`, hoặc xoá liên kết `dl` hỏng rồi `mkdir dl` |
| `feeds.conf is present` | có file `feeds.conf` đè lên feed đã ghim | xoá `feeds.conf` |
| `kernel is not 6.12.94` | cây không ở đúng nền v25.12.5 | kiểm đang ở nhánh `ls1046-hw-accel-ask`, không có sửa đổi lạ trong `target/linux/generic` |
| `package <tên> is not selected` | một gói bắt buộc rơi khỏi `.config` sau `make defconfig`, thường vì feed chưa cài xong | chạy lại giai đoạn `toolchain`; xem log của `./scripts/feeds` |
| `image build failed; full log in logs/hwaccel-build-verbose.log` | một gói build lỗi | script đã tự build lại với một luồng; 120 dòng cuối của file đó nằm trong log chính, lỗi thật ở gần cuối |
| lỗi khi build `golang` trên arm64 | không có bản Go để khởi đầu | bước 1, `GO_BOOTSTRAP_ROOT` |
| `npx: command not found` hoặc lỗi tải `esbuild` | Node.js của máy build chưa được build xong, hoặc không tới được kho npm | kiểm mạng; chạy lại giai đoạn `image` |
| tải nguồn thất bại (`Download failed`) | không tới được `github.com` hay mirror của OpenWrt | kiểm mạng, proxy; chạy lại, các file đã tải được giữ trong `dl` |

## Hai điều không được làm với repo này

- Không commit hay push microcode ASK (bước 3.2).
- Không dùng `git push --tags`: một bản clone có thể mang tag của OpenWrt
  upstream (như `v25.12.5`), không thuộc về repo này. Chỉ push nhánh:
  `git push origin hw-accel`.
