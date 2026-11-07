#!/usr/bin/env bash
#
# install-openclaw-lxc.sh
#
# Tao mot LXC Ubuntu (template chuan cua Proxmox, hoac rootfs "minimal" build bang
# debootstrap) tren Proxmox VE 8.x / 9.x, roi cai OpenClaw ben trong container va
# cau hinh Gateway chay nhu systemd user service, tu bat sau khi reboot.
#
# Chay TREN HOST Proxmox, bang root:
#   ./install-openclaw-lxc.sh --help
#
# Khong chay script nay ben trong container.
#
set -Eeuo pipefail

SCRIPT_NAME=${0##*/}
SCRIPT_VERSION="1.0.0"
LOG_FILE=${LOG_FILE:-/var/log/openclaw-lxc-$(date +%Y%m%d-%H%M%S).log}

# ------------------------------------------------------------------ defaults
CTID=""
CT_HOSTNAME="openclaw"
CT_CORES=2
CT_MEMORY=4096          # MB
CT_SWAP=512             # MB
CT_DISK=16              # GB
CT_IP="dhcp"
CT_GW=""
CT_NAMESERVER=""
CT_PASSWORD=""
SSH_KEY_FILE=""
ROOTFS_STORAGE=""
TMPL_STORAGE=""
BRIDGE=""
UBUNTU_VER="24.04"
UBUNTU_CODENAME=""
TEMPLATE_MODE="standard"
MIRROR=""
GATEWAY_BIND="lan"
GATEWAY_PORT="18789"
PROVIDER=""
PROVIDER_KEY=""
ONBOARD_EXTRA=""
SKIP_OPENCLAW=0
DRY_RUN=0
DESTROY_ON_FAILURE=0
TMPL_VOL=""
CREATED_CT=""
PAYLOAD_TMP=""
ENV_TMP=""

# ------------------------------------------------------------------ helpers
if [[ -t 1 ]]; then
	CLR_STEP=$'\033[1;36m'; CLR_WARN=$'\033[1;33m'; CLR_ERR=$'\033[1;31m'; CLR_OFF=$'\033[0m'
else
	CLR_STEP=""; CLR_WARN=""; CLR_ERR=""; CLR_OFF=""
fi

log()  { printf '%s==>%s %s\n' "$CLR_STEP" "$CLR_OFF" "$*"; }
warn() { printf '%s[!]%s %s\n' "$CLR_WARN" "$CLR_OFF" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$CLR_ERR" "$CLR_OFF" "$*" >&2; exit 1; }

cleanup() {
	[[ -n $PAYLOAD_TMP && -f $PAYLOAD_TMP ]] && rm -f "$PAYLOAD_TMP"
	[[ -n $ENV_TMP && -f $ENV_TMP ]] && rm -f "$ENV_TMP"
	return 0
}

on_error() {
	local rc=$?
	printf '\n%s[x]%s Loi (exit %s) tai dong %s: %s\n' \
		"$CLR_ERR" "$CLR_OFF" "$rc" "${BASH_LINENO[0]:-?}" "${BASH_COMMAND:-unknown}" >&2
	printf '%s[x]%s Log day du: %s\n' "$CLR_ERR" "$CLR_OFF" "$LOG_FILE" >&2
	if [[ -n $CREATED_CT ]]; then
		if ((DESTROY_ON_FAILURE)); then
			warn "Dang xoa container $CREATED_CT (--destroy-on-failure)"
			pct stop "$CREATED_CT" >/dev/null 2>&1 || true
			pct destroy "$CREATED_CT" --purge >/dev/null 2>&1 || true
		else
			warn "Container $CREATED_CT duoc giu lai de debug."
			warn "Xoa thu cong: pct stop $CREATED_CT && pct destroy $CREATED_CT --purge"
		fi
	fi
	cleanup
	exit "$rc"
}

trap on_error ERR
trap cleanup EXIT

run() { # chay lenh, day toan bo output vao log
	printf '+ %s\n' "$*" >>"$LOG_FILE"
	"$@" >>"$LOG_FILE" 2>&1 || die "Lenh that bai: $* (xem $LOG_FILE)"
}

need_root() {
	[[ ${EUID:-$(id -u)} -eq 0 ]] || die "Phai chay bang root tren host Proxmox."
}

need_host_tools() {
	local missing=() c
	for c in pct pveam pvesm pvesh; do
		command -v "$c" >/dev/null 2>&1 || missing+=("$c")
	done
	((${#missing[@]} == 0)) || die "Khong tim thay: ${missing[*]}. Script nay phai chay tren host Proxmox VE."
	[[ -d /etc/pve ]] || die "/etc/pve khong ton tai - day khong phai host Proxmox VE."
}

usage() {
	cat <<EOF
$SCRIPT_NAME $SCRIPT_VERSION - Tao LXC Ubuntu + cai OpenClaw tren Proxmox VE

CACH DUNG
  ./$SCRIPT_NAME [tuy chon]

VI DU
  # Don gian nhat: Ubuntu 24.04 template chuan, DHCP, 4GB RAM, 16GB disk
  ./$SCRIPT_NAME

  # Rootfs "minimal" (debootstrap): nho hon, sach hon, lau hon (~5-15 phut)
  ./$SCRIPT_NAME --minimal --ctid 210 --hostname claw --memory 6144 --disk 24

  # IP tinh + onboarding tu dong voi Anthropic API key, mo Control UI trong LAN
  ./$SCRIPT_NAME --ip 192.168.1.50/24 --gw 192.168.1.1 \\
      --anthropic-key "\$ANTHROPIC_API_KEY" --bind lan

CONTAINER
  --ctid <id>              VMID (mac dinh: id trong tiep theo cua cluster)
  --hostname <name>        hostname cua CT (mac dinh: openclaw)
  --cores <n>              so vCPU (mac dinh: 2)
  --memory <mb>            RAM MB (mac dinh: 4096, toi thieu 2048)
  --swap <mb>              swap MB (mac dinh: 512)
  --disk <gb>              dung luong rootfs GB (mac dinh: 16, toi thieu 8)
  --storage <id>           storage cho rootfs (mac dinh: tu dong)
  --bridge <vmbr>          bridge mang (mac dinh: vmbr dau tien tim thay)
  --ip <dhcp|CIDR>         IP cua eth0 (mac dinh: dhcp)
  --gw <ip>                gateway (bat buoc khi --ip la CIDR)
  --nameserver <ip>        DNS cho CT (mac dinh: theo host)
  --password <pass>        password root (mac dinh: khong dat - vao bang 'pct enter' hoac SSH key)
  --ssh-key <file>         public key cua ban (lap lai duoc nhieu lan)

UBUNTU / TEMPLATE
  --ubuntu <ver>           phien ban Ubuntu (mac dinh: 24.04)
  --ubuntu-codename <c>    codename khi dung --minimal (vd: noble, jammy)
  --minimal                build rootfs bang debootstrap thay vi template chuan
  --mirror <url>           mirror cho debootstrap
  --template-storage <id>  storage cho template (mac dinh: tu dong)

OPENCLAW
  --skip-openclaw          chi tao container, khong cai OpenClaw
  --bind <mode>            gateway.bind: loopback|lan|tailnet|custom|auto (mac dinh: lan)
  --port <port>            gateway port (mac dinh: 18789)
  --anthropic-key <key>    onboarding non-interactive voi Anthropic API key
  --openai-key <key>       onboarding non-interactive voi OpenAI API key
  --onboard-extra "<args>" args bo sung truyen thang cho 'openclaw onboard'
  (khong truyen key => chi cai dat, ban tu chay onboarding sau)

KHAC
  --dry-run                chi in ke hoach, khong tao gi
  --destroy-on-failure     xoa container neu cai dat that bai
  --log <file>             duong dan log (mac dinh: /var/log/openclaw-lxc-<time>.log)
  -h, --help               tro giup

SAU KHI CAI
  pct enter <ctid>                                  # vao container
  openclaw onboard                                  # setup AI provider (neu chua co key)
  openclaw dashboard                                # mo Control UI (in URL + token)
  pct exec <ctid> -- bash -lc 'openclaw gateway status --deep'
EOF
}

show_summary() {
	local ip=${1:-} url hint
	if [[ -n $ip ]]; then
		if [[ $GATEWAY_BIND == "loopback" ]]; then
			url="http://127.0.0.1:${GATEWAY_PORT}  (chi loopback)"
			hint="ssh -N -L ${GATEWAY_PORT}:127.0.0.1:${GATEWAY_PORT} root@${ip}"
		else
			url="http://${ip}:${GATEWAY_PORT}"
			hint=""
		fi
	else
		url="http://<ip-container>:${GATEWAY_PORT}"
		hint=""
	fi

	cat <<EOF

=========================================================================
 HOAN TAT
=========================================================================
 Container : ${CTID} (${CT_HOSTNAME})
 IP        : ${ip:-chua co (kiem tra DHCP/bridge)}
 Control UI: ${url}
 Log       : ${LOG_FILE}
EOF
	[[ -n $hint ]] && printf ' SSH tunnel: %s\n' "$hint"

	if ((SKIP_OPENCLAW)); then
		cat <<EOF

 OpenClaw CHUA duoc cai (--skip-openclaw). Container da san sang:
   pct enter ${CTID}
EOF
	else
		cat <<EOF

 Buoc tiep theo:

   # 1. Vao container
   pct enter ${CTID}

   # 2. Neu chua chay onboarding (chua truyen API key)
   openclaw onboard

   # 3. Lay URL + token Control UI
   openclaw dashboard

   # 4. Kiem tra Gateway
   openclaw gateway status --deep
EOF
	fi

	cat <<EOF

 Luu y bao mat:
   - gateway.bind=${GATEWAY_BIND}: Gateway nghe tren moi interface trong container.
     Gateway bat buoc phai co auth token (onboarding tu sinh token). Neu mo ra
     ngoai LAN, hay dat gateway.bind=loopback + Tailscale/SSH tunnel va gioi han
     firewall o host.
   - Container la unprivileged LXC (nesting=1, keyctl=1): Docker ben trong
     container chay duoc, nhung khong phai moi thu trong LXC deu giong VM.
=========================================================================
EOF
}

# ------------------------------------------------------------------ args
while (($#)); do
	case "$1" in
		--ctid)               CTID=${2:?}; shift 2 ;;
		--hostname)           CT_HOSTNAME=${2:?}; shift 2 ;;
		--cores)              CT_CORES=${2:?}; shift 2 ;;
		--memory)             CT_MEMORY=${2:?}; shift 2 ;;
		--swap)               CT_SWAP=${2:?}; shift 2 ;;
		--disk)               CT_DISK=${2:?}; shift 2 ;;
		--storage)            ROOTFS_STORAGE=${2:?}; shift 2 ;;
		--template-storage)   TMPL_STORAGE=${2:?}; shift 2 ;;
		--bridge)             BRIDGE=${2:?}; shift 2 ;;
		--ip)                 CT_IP=${2:?}; shift 2 ;;
		--gw)                 CT_GW=${2:?}; shift 2 ;;
		--nameserver)         CT_NAMESERVER=${2:?}; shift 2 ;;
		--password)           CT_PASSWORD=${2:?}; shift 2 ;;
		--ssh-key)            SSH_KEY_FILE=${2:?}; shift 2 ;;
		--ubuntu)             UBUNTU_VER=${2:?}; shift 2 ;;
		--ubuntu-codename)    UBUNTU_CODENAME=${2:?}; shift 2 ;;
		--minimal)            TEMPLATE_MODE="minimal"; shift ;;
		--mirror)             MIRROR=${2:?}; shift 2 ;;
		--bind)               GATEWAY_BIND=${2:?}; shift 2 ;;
		--port)               GATEWAY_PORT=${2:?}; shift 2 ;;
		--anthropic-key)      PROVIDER="anthropic"; PROVIDER_KEY=${2:?}; shift 2 ;;
		--openai-key)         PROVIDER="openai";    PROVIDER_KEY=${2:?}; shift 2 ;;
		--onboard-extra)      ONBOARD_EXTRA=${2:?}; shift 2 ;;
		--skip-openclaw)      SKIP_OPENCLAW=1; shift ;;
		--dry-run)            DRY_RUN=1; shift ;;
		--destroy-on-failure) DESTROY_ON_FAILURE=1; shift ;;
		--log)                LOG_FILE=${2:?}; shift 2 ;;
		-h|--help)            usage; exit 0 ;;
		*)                    usage >&2; die "Tuy chon khong hop le: $1" ;;
	esac
done

# ------------------------------------------------------------------ validate
[[ $CT_CORES =~ ^[0-9]+$ ]]     || die "--cores phai la so"
[[ $CT_MEMORY =~ ^[0-9]+$ ]]    || die "--memory phai la so (MB)"
[[ $CT_SWAP =~ ^[0-9]+$ ]]      || die "--swap phai la so (MB)"
[[ $CT_DISK =~ ^[0-9]+$ ]]      || die "--disk phai la so (GB)"
[[ $GATEWAY_PORT =~ ^[0-9]+$ ]] || die "--port phai la so"
((CT_MEMORY >= 2048)) || die "--memory toi thieu 2048 MB (Gateway can heap >= 2GB)"
((CT_DISK >= 8))      || die "--disk toi thieu 8 GB"

case "$GATEWAY_BIND" in
	loopback|lan|tailnet|custom|auto) ;;
	*) die "--bind phai la: loopback|lan|tailnet|custom|auto" ;;
esac

if [[ $CT_IP != "dhcp" ]]; then
	[[ $CT_IP == */* ]] || die "--ip phai la 'dhcp' hoac dang CIDR, vd 192.168.1.50/24"
	[[ -n $CT_GW ]] || die "Khi --ip la CIDR thi bat buoc phai co --gw"
fi

if [[ -n $SSH_KEY_FILE && ! -r $SSH_KEY_FILE ]]; then
	die "Khong doc duoc SSH key: $SSH_KEY_FILE"
fi
if [[ -n $SSH_KEY_FILE && -n $CT_PASSWORD ]]; then
	die "Chon mot trong hai: --password hoac --ssh-key"
fi

# codename map - chi khai bao cac ban da chac chan
case "$UBUNTU_VER" in
	22.04) DEF_CODENAME="jammy" ;;
	24.04) DEF_CODENAME="noble" ;;
	24.10) DEF_CODENAME="oracular" ;;
	25.04) DEF_CODENAME="plucky" ;;
	25.10) DEF_CODENAME="questing" ;;
	*)     DEF_CODENAME="" ;;
esac
if [[ -z $UBUNTU_CODENAME ]]; then
	if [[ -z $DEF_CODENAME && $TEMPLATE_MODE == "minimal" ]]; then
		die "--minimal voi Ubuntu $UBUNTU_VER can --ubuntu-codename (vd: --ubuntu-codename noble)"
	fi
	UBUNTU_CODENAME=${DEF_CODENAME}
fi

# ------------------------------------------------------------------ detect
ARCH=$(dpkg --print-architecture)
case "$ARCH" in
	amd64) ARCH_TMPL="amd64"; DEF_MIRROR="http://archive.ubuntu.com/ubuntu" ;;
	arm64) ARCH_TMPL="arm64"; DEF_MIRROR="http://ports.ubuntu.com/ubuntu-ports" ;;
	*) die "Kien truc host khong ho tro: $ARCH" ;;
esac
MIRROR=${MIRROR:-$DEF_MIRROR}

detect_bridge() {
	local b=""
	b=$(awk '/^iface[[:space:]]+vmbr[0-9]+[[:space:]]+inet/{print $2; exit}' /etc/network/interfaces 2>/dev/null || true)
	printf '%s\n' "${b:-vmbr0}"
}

choose_storage() { # $1=content, $2..N=cac loai storage uu tien
	local content=$1; shift
	local listing hit t
	listing=$(pvesm status --content "$content" 2>/dev/null \
		| awk 'NR>1 && $3=="active"{print $2":"$1}' || true)

	# fallback: doc thang /etc/pve/storage.cfg neu pvesm khong tra ve gi
	if [[ -z $listing && -r /etc/pve/storage.cfg ]]; then
		listing=$(awk -v want="$content" '
			/^[a-z0-9]+:[[:space:]]/ {
				if (id != "" && ok) print type ":" id
				type = $1; sub(/:$/, "", type); id = $2; ok = 0; next
			}
			{
				for (i = 1; i < NF; i++)
					if ($i == "content" && index($(i + 1), want) > 0) ok = 1
			}
			END { if (id != "" && ok) print type ":" id }
		' /etc/pve/storage.cfg)
	fi

	[[ -n $listing ]] || return 1
	for t in "$@"; do
		hit=$(printf '%s\n' "$listing" | awk -F: -v t="$t" '$1==t{print $2; exit}')
		if [[ -n $hit ]]; then
			printf '%s\n' "$hit"
			return 0
		fi
	done
	printf '%s\n' "$listing" | awk -F: 'NR==1{print $2}'
}

next_ctid() {
	local id=""
	id=$(pvesh get /cluster/nextid --output-format json 2>/dev/null | tr -d '"' || true)
	[[ $id =~ ^[0-9]+$ ]] || id=100
	printf '%s\n' "$id"
}

find_std_template() {
	pveam available --section system 2>/dev/null \
		| awk -v re="^ubuntu-${UBUNTU_VER}-standard_.*_${ARCH_TMPL}\\.tar\\.(zst|xz|gz)\$" \
			'{ for (i = 1; i <= NF; i++) if ($i ~ re) { print $i; break } }' \
		| sort -V | tail -n 1
}

# ------------------------------------------------------------------ template
download_standard_template() {
	local tmpl
	tmpl=$(find_std_template)
	if [[ -z $tmpl ]]; then
		warn "Chua thay template Ubuntu $UBUNTU_VER trong danh sach - chay 'pveam update'..."
		pveam update >>"$LOG_FILE" 2>&1 || true
		tmpl=$(find_std_template)
	fi
	[[ -n $tmpl ]] || die "Khong tim thay template 'ubuntu-$UBUNTU_VER-standard' cho $ARCH_TMPL.
       Thu: pveam update && pveam available --section system | grep ubuntu
       Hoac dung: --minimal (build bang debootstrap)"

	if ((DRY_RUN)); then
		log "[dry-run] se dam bao co template: $tmpl tren '$TMPL_STORAGE'"
		TMPL_VOL="${TMPL_STORAGE}:vztmpl/${tmpl}"
		return 0
	fi

	if pveam list "$TMPL_STORAGE" 2>/dev/null | grep -q "$tmpl"; then
		log "Template da co san: $tmpl"
	else
		log "Tai template: $tmpl -> storage '$TMPL_STORAGE'"
		run pveam download "$TMPL_STORAGE" "$tmpl"
	fi
	TMPL_VOL="${TMPL_STORAGE}:vztmpl/${tmpl}"
}

build_minimal_template() {
	local name out rootdir keyring keyarg=()
	name="ubuntu-${UBUNTU_CODENAME}-minimal_${UBUNTU_VER}_${ARCH_TMPL}.tar.zst"

	out=$(pvesm path "${TMPL_STORAGE}:vztmpl/${name}" 2>/dev/null | tail -n 1 || true)
	[[ -n $out ]] || die "Khong resolve duoc duong dan template tren '$TMPL_STORAGE'.
       --minimal can storage kieu 'dir' (hoac NFS/CIFS) co content 'vztmpl'."

	if [[ -s $out ]]; then
		log "Da co rootfs minimal: $out"
		TMPL_VOL="${TMPL_STORAGE}:vztmpl/${name}"
		return 0
	fi

	if ((DRY_RUN)); then
		log "[dry-run] se debootstrap $UBUNTU_CODENAME va tao: $out"
		TMPL_VOL="${TMPL_STORAGE}:vztmpl/${name}"
		return 0
	fi

	log "Cai debootstrap + ubuntu-keyring tren host"
	run env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
		debootstrap ubuntu-keyring zstd ca-certificates

	rootdir=$(mktemp -d /var/tmp/openclaw-minimal-rootfs.XXXXXX)
	# shellcheck disable=SC2064
	trap "rm -rf '$rootdir'; cleanup" EXIT

	keyring=/usr/share/keyrings/ubuntu-archive-keyring.gpg
	if [[ -r $keyring ]]; then
		keyarg=(--keyring="$keyring")
	fi

	log "debootstrap $UBUNTU_CODENAME ($ARCH) vao $rootdir (5-15 phut)"
	run env DEBIAN_FRONTEND=noninteractive debootstrap \
		--variant=minbase --arch="$ARCH" --components=main,universe \
		"${keyarg[@]}" \
		--include=systemd,systemd-sysv,libpam-systemd,dbus,udev,kmod,ifupdown,isc-dhcp-client,iproute2,iputils-ping,netbase,ca-certificates,curl,gnupg,git,tzdata,locales,procps,psmisc,less,nano,openssh-server,apt-utils,zstd,xz-utils,tar,rsync,unzip \
		"$UBUNTU_CODENAME" "$rootdir" "$MIRROR"

	log "Don dep rootfs"
	chroot "$rootdir" /usr/bin/env DEBIAN_FRONTEND=noninteractive /bin/bash -c 'apt-get clean' \
		>>"$LOG_FILE" 2>&1 || true
	rm -rf "$rootdir"/var/lib/apt/lists/* \
		"$rootdir"/var/cache/apt/archives/*.deb \
		"$rootdir"/var/cache/apt/archives/partial/* \
		"$rootdir"/var/log/* \
		"$rootdir"/usr/share/info/* \
		"$rootdir"/usr/share/man/* \
		"$rootdir"/usr/share/doc/* 2>/dev/null || true
	mkdir -p "$rootdir"/var/log/apt "$rootdir"/var/lib/apt/lists/partial
	: >"$rootdir"/etc/machine-id   # de systemd sinh machine-id moi cho tung container
	: >"$rootdir"/etc/hostname

	mkdir -p "$(dirname "$out")"
	log "Dong goi rootfs -> $out"
	printf '+ tar | zstd -9 -> %s\n' "$out" >>"$LOG_FILE"
	tar -C "$rootdir" --numeric-owner --xattrs --acls \
		--exclude=./dev/* --exclude=./proc/* --exclude=./sys/* --exclude=./run/* \
		-cf - . | zstd -T0 -9 -q -f -o "$out" >>"$LOG_FILE" 2>&1

	rm -rf "$rootdir"
	trap cleanup EXIT

	[[ -s $out ]] || die "Tao rootfs minimal that bai"
	TMPL_VOL="${TMPL_STORAGE}:vztmpl/${name}"
}

# ------------------------------------------------------------------ payload
write_payload() {
	PAYLOAD_TMP=$(mktemp /tmp/openclaw-provision.XXXXXX.sh)
	cat >"$PAYLOAD_TMP" <<'OPENCLAW_PAYLOAD'
#!/usr/bin/env bash
# Payload chay BEN TRONG container (duoc day vao /root/openclaw-provision.sh)
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

ENV_FILE=/root/.openclaw-provision.env
# shellcheck disable=SC1090
source "$ENV_FILE"

step() { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }

step "apt update + nang cap he thong"
apt-get update -q
apt-get -y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade

step "Cai goi nen"
apt-get -y -q install --no-install-recommends \
	ca-certificates curl git gnupg jq tzdata procps psmisc zstd xz-utils \
	tar unzip rsync less nano openssh-server libatomic1

systemctl enable --now ssh >/dev/null 2>&1 || systemctl enable --now sshd >/dev/null 2>&1 || true

if [[ "${SKIP_OPENCLAW}" == "1" ]]; then
	step "Bo qua cai OpenClaw (--skip-openclaw)"
	exit 0
fi

step "Cai OpenClaw (installer chinh thuc, tu cai Node.js LTS neu thieu)"
if command -v openclaw >/dev/null 2>&1; then
	warn "openclaw da co san: $(openclaw --version 2>/dev/null || echo '?')"
else
	curl -fsSL --proto '=https' --tlsv1.2 https://openclaw.ai/install.sh \
		| bash -s -- --no-prompt --no-onboard
fi
hash -r
if ! command -v openclaw >/dev/null 2>&1; then
	echo "Khong tim thay binary openclaw sau khi cai" >&2
	exit 1
fi
echo "openclaw: $(openclaw --version)"
echo "node:     $(node --version)"
echo "npm:      $(npm --version)"

step "Bat systemd user lingering (Gateway tu chay sau reboot)"
if command -v loginctl >/dev/null 2>&1; then
	loginctl enable-linger root || warn "loginctl enable-linger that bai"
	systemctl start user@0.service || warn "khong start duoc user@0.service"
	for ((i = 0; i < 20; i++)); do
		[[ -S /run/user/0/bus ]] && break
		sleep 0.5
	done
	install -d -m 0700 /run/user/0
	export XDG_RUNTIME_DIR=/run/user/0
	export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/0/bus"
	# 'pct enter' khong tao PAM session, nen XDG_RUNTIME_DIR thuong bi thieu.
	# Them ca .bashrc (shell tuong tac) va profile.d (shell login).
	cat >/etc/profile.d/openclaw-xdg.sh <<'EOS'
if [ -z "${XDG_RUNTIME_DIR:-}" ] && [ -d "/run/user/$(id -u)" ]; then
	export XDG_RUNTIME_DIR="/run/user/$(id -u)"
	export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
fi
EOS
	if ! grep -q 'openclaw-xdg' /root/.bashrc 2>/dev/null; then
		printf '\n. /etc/profile.d/openclaw-xdg.sh  # openclaw-xdg\n' >>/root/.bashrc
	fi
	systemctl --user is-system-running >/dev/null 2>&1 \
		|| warn "systemd --user (root) chua san sang; Gateway service co the khong cai duoc"
else
	warn "Khong co loginctl - systemd user service se khong tu chay sau reboot"
fi

# ---- onboarding
ONBOARD_ARGS=()
if [[ -n "${ANTHROPIC_KEY}" ]]; then
	ONBOARD_ARGS=(--auth-choice apiKey --anthropic-api-key "${ANTHROPIC_KEY}" --secret-input-mode plaintext)
elif [[ -n "${OPENAI_KEY}" ]]; then
	export OPENAI_API_KEY="${OPENAI_KEY}"
	ONBOARD_ARGS=(--auth-choice openai-api-key --secret-input-mode plaintext)
fi

if ((${#ONBOARD_ARGS[@]} > 0)); then
	step "Onboarding non-interactive (provider=${PROVIDER}, bind=${GATEWAY_BIND}:${GATEWAY_PORT})"
	EXTRA=()
	if [[ -n "${ONBOARD_EXTRA}" ]]; then
		read -r -a EXTRA <<<"${ONBOARD_EXTRA}"
	fi
	set +e
	openclaw onboard --non-interactive --accept-risk \
		--mode local \
		"${ONBOARD_ARGS[@]}" \
		--gateway-bind "${GATEWAY_BIND}" \
		--gateway-port "${GATEWAY_PORT}" \
		--install-daemon --daemon-runtime node \
		"${EXTRA[@]}"
	rc=$?
	set -e
	if ((rc != 0)); then
		warn "onboarding non-interactive that bai (exit $rc)."
		warn "CLI + container van OK. Chay lai thu cong:"
		warn "  pct enter <ctid>   ->   openclaw onboard"
		exit 0
	fi
else
	step "Chua co API key, bo qua onboarding"
	cat <<'EOS'
    Cai dat xong nhung chua co model provider nao.
    Chay onboarding tuong tac tu host:

        pct enter <ctid>
        openclaw onboard          # chon provider, cai Gateway service (--install-daemon)

    Sau do: openclaw dashboard   # in URL + token Control UI
EOS
	exit 0
fi

step "Kiem tra Gateway"
openclaw gateway status --deep || warn "Gateway chua healthy (xem: openclaw logs)"

step "Xong"
echo "Gateway: bind=${GATEWAY_BIND} port=${GATEWAY_PORT}"
echo "URL + token Control UI:  openclaw dashboard"
OPENCLAW_PAYLOAD
	chmod 0755 "$PAYLOAD_TMP"
}

write_env_file() {
	local ak="" ok=""
	if [[ $PROVIDER == "anthropic" ]]; then ak=$PROVIDER_KEY; fi
	if [[ $PROVIDER == "openai" ]]; then ok=$PROVIDER_KEY; fi

	ENV_TMP=$(mktemp /tmp/openclaw-provision.XXXXXX.env)
	{
		printf 'PROVIDER=%q\n'      "$PROVIDER"
		printf 'ANTHROPIC_KEY=%q\n' "$ak"
		printf 'OPENAI_KEY=%q\n'    "$ok"
		printf 'SKIP_OPENCLAW=%q\n' "$SKIP_OPENCLAW"
		printf 'GATEWAY_BIND=%q\n'  "$GATEWAY_BIND"
		printf 'GATEWAY_PORT=%q\n'  "$GATEWAY_PORT"
		printf 'ONBOARD_EXTRA=%q\n' "$ONBOARD_EXTRA"
	} >"$ENV_TMP"
	chmod 0600 "$ENV_TMP"
}

# ------------------------------------------------------------------ main
need_root
need_host_tools
if ! { : >>"$LOG_FILE"; } 2>/dev/null; then
	warn "Khong ghi duoc $LOG_FILE, chuyen sang /tmp"
	LOG_FILE=/tmp/${LOG_FILE##*/}
	: >>"$LOG_FILE"
fi

log "$SCRIPT_NAME $SCRIPT_VERSION  (log: $LOG_FILE)"

CTID=${CTID:-$(next_ctid)}
[[ $CTID =~ ^[0-9]+$ ]] || die "--ctid phai la so"
if pct status "$CTID" >/dev/null 2>&1; then
	die "VMID $CTID da ton tai. Chon --ctid khac."
fi

if [[ -z $TMPL_STORAGE ]]; then
	TMPL_STORAGE=$(choose_storage vztmpl dir nfs cifs cephfs || true)
fi
[[ -n $TMPL_STORAGE ]] || die "Khong tim thay storage nao co content 'vztmpl'."

if [[ -z $ROOTFS_STORAGE ]]; then
	ROOTFS_STORAGE=$(choose_storage rootdir lvmthin zfspool btrfs dir || true)
fi
[[ -n $ROOTFS_STORAGE ]] || die "Khong tim thay storage nao co content 'rootdir'."

BRIDGE=${BRIDGE:-$(detect_bridge)}

log "Ke hoach: CT $CTID '$CT_HOSTNAME'  ${CT_CORES} vCPU / ${CT_MEMORY}MB RAM / ${CT_DISK}GB"
log "          rootfs=$ROOTFS_STORAGE  template=$TMPL_STORAGE  bridge=$BRIDGE  ip=$CT_IP"
log "          ubuntu=$UBUNTU_VER  mode=$TEMPLATE_MODE  gateway=$GATEWAY_BIND:$GATEWAY_PORT"

if [[ $TEMPLATE_MODE == "minimal" ]]; then
	build_minimal_template
else
	download_standard_template
fi

NET0="name=eth0,bridge=${BRIDGE},ip=${CT_IP}"
if [[ -n $CT_GW ]]; then NET0+=",gw=${CT_GW}"; fi

# shellcheck disable=SC2054  # nesting=1,keyctl=1 la mot tu duy nhat, khong phai 2 phan tu
CREATE_ARGS=(
	"$CTID" "$TMPL_VOL"
	--hostname "$CT_HOSTNAME"
	--description "Ubuntu $UBUNTU_VER LXC - OpenClaw Gateway (tao boi $SCRIPT_NAME $SCRIPT_VERSION)"
	--ostype ubuntu
	--arch "$ARCH_TMPL"
	--unprivileged 1
	--features nesting=1,keyctl=1
	--cores "$CT_CORES"
	--memory "$CT_MEMORY"
	--swap "$CT_SWAP"
	--rootfs "${ROOTFS_STORAGE}:${CT_DISK}"
	--net0 "$NET0"
	--onboot 1
	--timezone host
	--tags openclaw
)
[[ -n $CT_NAMESERVER ]] && CREATE_ARGS+=(--nameserver "$CT_NAMESERVER")
if [[ -n $CT_PASSWORD ]]; then
	CREATE_ARGS+=(--password "$CT_PASSWORD")
elif [[ -n $SSH_KEY_FILE ]]; then
	CREATE_ARGS+=(--ssh-public-keys "$SSH_KEY_FILE")
fi

if ((DRY_RUN)); then
	log "DRY-RUN - lenh se chay:"
	printf 'pct create'
	redact=0
	for a in "${CREATE_ARGS[@]}"; do
		if ((redact)); then printf ' %q' '<redacted>'; redact=0; continue; fi
		printf ' %q' "$a"
		[[ $a == "--password" ]] && redact=1
	done
	printf '\n'
	exit 0
fi

log "Tao container $CTID"
printf '+ pct create %s (argv chua password da bi an)\n' "$CTID" >>"$LOG_FILE"
if ! pct create "${CREATE_ARGS[@]}" >>"$LOG_FILE" 2>&1; then
	die "pct create that bai (xem $LOG_FILE)"
fi
CREATED_CT=$CTID

log "Khoi dong container"
if ! pct start "$CTID" >>"$LOG_FILE" 2>&1; then
	die "pct start that bai (xem $LOG_FILE)"
fi

log "Cho container boot xong"
ready=0
for ((i = 1; i <= 90; i++)); do
	if pct exec "$CTID" -- /bin/true >/dev/null 2>&1; then
		st=$(pct exec "$CTID" -- systemctl is-system-running 2>/dev/null || true)
		case "$st" in
			running|degraded) ready=1; break ;;
		esac
	fi
	sleep 2
done
((ready == 1)) || die "Container khong san sang sau 180s (xem: pct enter $CTID; journalctl -b)"

ipaddr=$(pct exec "$CTID" -- sh -c "ip -4 -o addr show dev eth0 2>/dev/null | awk '{print \$4}' | cut -d/ -f1" || true)
if [[ -z $ipaddr ]]; then
	warn "eth0 chua co IPv4. Kiem tra DHCP/bridge '$BRIDGE' bang: pct exec $CTID -- ip a"
else
	log "IP container: $ipaddr"
fi

if ((SKIP_OPENCLAW)); then
	log "Bo qua cai OpenClaw theo yeu cau (--skip-openclaw)."
	CREATED_CT=""
	show_summary "$ipaddr"
	exit 0
fi

log "Day payload cai dat vao container"
write_payload
write_env_file
pct push "$CTID" "$PAYLOAD_TMP" /root/openclaw-provision.sh --perms 0755 >>"$LOG_FILE" 2>&1 \
	|| die "pct push payload that bai"
pct push "$CTID" "$ENV_TMP" /root/.openclaw-provision.env --perms 0600 >>"$LOG_FILE" 2>&1 \
	|| die "pct push env that bai"

log "Cai OpenClaw trong container (5-15 phut, output hien truc tiep ben duoi)"
if ! pct exec "$CTID" -- /root/openclaw-provision.sh 2>&1 | tee -a "$LOG_FILE"; then
	die "Cai dat trong container that bai (xem $LOG_FILE)"
fi
pct exec "$CTID" -- rm -f /root/.openclaw-provision.env >/dev/null 2>&1 || true

CREATED_CT=""
show_summary "$ipaddr"
