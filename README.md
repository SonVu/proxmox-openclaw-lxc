# OpenClaw trên Proxmox LXC (Ubuntu)

Script tạo LXC **Ubuntu** trên Proxmox VE rồi cài **OpenClaw** + Gateway bên trong
container.

- File: `install-openclaw-lxc.sh`
- Chạy **trên host Proxmox**, bằng `root`. Không chạy trong container.
- Đã kiểm tra: `bash -n`, `shellcheck -S style` (sạch), dry-run với stub `pct/pveam/pvesm`.

## Script làm gì

1. Kiểm tra môi trường Proxmox (`pct`, `pveam`, `pvesm`, `/etc/pve`).
2. Tự chọn storage cho `rootdir` và `vztmpl`, tự chọn bridge (`vmbr0` mặc định).
3. Chuẩn bị rootfs Ubuntu, theo 1 trong 2 chế độ:
   - `standard` (mặc định): tải template chính thức của Proxmox
     (`ubuntu-24.04-standard_..._amd64.tar.zst`) qua `pveam`.
   - `--minimal`: build rootfs bằng `debootstrap --variant=minbase` + keyring
     `ubuntu-keyring`, dọn doc/man/apt cache, đóng gói `.tar.zst` rồi đăng ký
     làm template. Nhỏ và sạch hơn template chuẩn, nhưng mất 5–15 phút.
4. `pct create` container **unprivileged**, `nesting=1`, `keyctl=1` (đủ để
   systemd chạy đúng và dùng được Docker sandbox sau này), `onboot=1`.
5. Đợi container boot xong (`systemctl is-system-running`).
6. Đẩy payload vào `/root/openclaw-provision.sh` (kèm env file `0600`, xoá sau khi
   chạy) rồi:
   - `apt update` + `upgrade`, cài gói nền;
   - cài OpenClaw bằng installer chính thức (`https://openclaw.ai/install.sh`,
     tự cài Node.js LTS nếu thiếu);
   - `loginctl enable-linger root` + `user@0.service` + `XDG_RUNTIME_DIR`, để
     Gateway chạy như systemd **user** service và tự bật sau reboot;
   - nếu có API key: `openclaw onboard --non-interactive ... --install-daemon`;
   - kiểm tra `openclaw gateway status --deep`.

## Dùng nhanh

```bash
# Copy script lên host Proxmox rồi:
chmod +x install-openclaw-lxc.sh

./install-openclaw-lxc.sh --dry-run          # xem trước, không tạo gì
./install-openclaw-lxc.sh                    # Ubuntu 24.04, DHCP, 4GB RAM, 16GB
```

### Ubuntu 24.04 "minimal" (debootstrap)

```bash
./install-openclaw-lxc.sh --minimal \
  --ctid 210 --hostname claw \
  --memory 6144 --cores 4 --disk 24 \
  --ip 192.168.1.50/24 --gw 192.168.1.1
```

`--minimal` cần storage `dir` (hoặc NFS/CIFS) cho `vztmpl`, vì phải ghi file
`.tar.zst` trực tiếp vào thư mục template.

### Cài + cấu hình AI provider không tương tác

```bash
./install-openclaw-lxc.sh --anthropic-key "$ANTHROPIC_API_KEY" --bind lan
# hoặc
./install-openclaw-lxc.sh --openai-key "$OPENAI_API_KEY" --bind lan
```

Không truyền key → script chỉ cài đặt; bạn tự chạy `openclaw onboard` sau.

## Các tuỳ chọn chính

| Tuỳ chọn | Mặc định | Ý nghĩa |
| --- | --- | --- |
| `--ctid` | id trống kế tiếp | VMID của container |
| `--hostname` | `openclaw` | hostname |
| `--cores` / `--memory` / `--swap` / `--disk` | 2 / 4096MB / 512MB / 16GB | tài nguyên (RAM tối thiểu 2048) |
| `--storage` / `--template-storage` | tự dò | storage cho rootfs / template |
| `--bridge` | `vmbr0` | bridge mạng |
| `--ip` / `--gw` | `dhcp` | `dhcp` hoặc CIDR + gateway |
| `--nameserver` | theo host | DNS |
| `--password` / `--ssh-key` | không đặt | truy cập root |
| `--ubuntu` | `24.04` | phiên bản Ubuntu |
| `--minimal` | tắt | build rootfs bằng debootstrap |
| `--ubuntu-codename` | suy ra từ version | bắt buộc với version lạ khi `--minimal` |
| `--bind` | `lan` | `gateway.bind`: `loopback`/`lan`/`tailnet`/`custom`/`auto` |
| `--port` | `18789` | cổng Gateway |
| `--anthropic-key` / `--openai-key` | – | onboarding non-interactive |
| `--onboard-extra` | – | tham số thêm truyền thẳng cho `openclaw onboard` |
| `--skip-openclaw` | tắt | chỉ tạo container |
| `--destroy-on-failure` | tắt | xoá container nếu lỗi |
| `--log` | `/var/log/openclaw-lxc-*.log` | log đầy đủ |

## Sau khi cài

```bash
pct enter 210                                  # vào container
openclaw onboard                               # nếu chưa cấu hình provider
openclaw dashboard                             # in URL + token Control UI
openclaw gateway status --deep
openclaw doctor
```

Nếu `systemctl --user` báo thiếu bus (thường gặp khi vào bằng `pct enter`):

```bash
export XDG_RUNTIME_DIR=/run/user/0
```

Script đã tạo `/etc/profile.d/openclaw-xdg.sh` và thêm vào `/root/.bashrc` để tự
động set biến này; shell đang mở trước khi cài thì cần export tay một lần.

## Bảo mật

- `--bind lan` cho Gateway nghe trên mọi interface trong container, **bắt buộc có
  auth token** (onboarding tự sinh) — Gateway sẽ từ chối khởi động nếu bind ra
  ngoài loopback mà chưa cấu hình auth.
- Muốn kín hơn: `--bind loopback`, rồi dùng SSH tunnel hoặc Tailscale Serve:

```bash
ssh -N -L 18789:127.0.0.1:18789 root@<ip-container>
```

- Container là LXC **unprivileged** — ranh giới bảo mật không giống VM. Đừng đưa
  container này ra Internet trực tiếp; hãy giới hạn firewall ở host.

## Xử lý sự cố

| Hiện tượng | Cách xử lý |
| --- | --- |
| `Khong tim thay template ...` | `pveam update` rồi chạy lại, hoặc dùng `--minimal` |
| Container không có IPv4 | `pct exec <id> -- ip a`; kiểm tra bridge/DHCP, hoặc đặt IP tĩnh |
| Gateway không tự chạy sau reboot | `pct exec <id> -- loginctl show-user root` (phải có `Linger=yes`) |
| `openclaw: command not found` | `pct enter <id>`, `hash -r`, kiểm tra `npm prefix -g` (phải là `/usr`) |
| Onboarding non-interactive lỗi | chạy tay `openclaw onboard` (tương tác) trong container |
| Muốn xoá sạch | `pct stop <id> && pct destroy <id> --purge` |

## Ghi chú kỹ thuật

- Script dùng installer chính thức của OpenClaw thay vì tự `npm i -g`, vì
  installer xử lý đúng phiên bản Node.js LTS hiện hành và các cờ
  `--allow-scripts` khác nhau giữa các bản npm.
- `--minimal` cố tình cài `ifupdown` + `isc-dhcp-client`: Proxmox ghi cấu hình
  mạng vào `/etc/network/interfaces` của guest và để guest tự `ifup`. Thiếu hai
  gói này container sẽ không có mạng.
- Rootfs minimal đặt `/etc/machine-id` rỗng để mỗi container sinh id riêng.
- Nếu cần sandbox bằng Docker bên trong LXC, `nesting=1,keyctl=1` đã bật sẵn.
# proxmox-openclaw-lxc
# proxmox-openclaw-lxc
