#!/usr/bin/env bash
#
# install-openclaw-lxc.sh
#
# Create an Ubuntu LXC container on Proxmox VE 8.x / 9.x (either from the stock
# Proxmox template or from a "minimal" rootfs built with debootstrap), then
# install OpenClaw inside the container and configure the Gateway to run as a
# systemd user service that comes back automatically after a reboot.
#
# Run ON the Proxmox HOST as root:
#   ./install-openclaw-lxc.sh --help
#
# Do not run this script inside a container.
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
GATEWAY_TOKEN=""
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
	printf '\n%s[x]%s Error (exit %s) at line %s: %s\n' \
		"$CLR_ERR" "$CLR_OFF" "$rc" "${BASH_LINENO[0]:-?}" "${BASH_COMMAND:-unknown}" >&2
	printf '%s[x]%s Full log: %s\n' "$CLR_ERR" "$CLR_OFF" "$LOG_FILE" >&2
	if [[ -n $CREATED_CT ]]; then
		if ((DESTROY_ON_FAILURE)); then
			warn "Destroying container $CREATED_CT (--destroy-on-failure)"
			pct stop "$CREATED_CT" >/dev/null 2>&1 || true
			pct destroy "$CREATED_CT" --purge >/dev/null 2>&1 || true
		else
			warn "Container $CREATED_CT kept for debugging."
			warn "Remove manually: pct stop $CREATED_CT && pct destroy $CREATED_CT --purge"
		fi
	fi
	cleanup
	exit "$rc"
}

trap on_error ERR
trap cleanup EXIT

run() { # run a command, capturing all output in the log
	printf '+ %s\n' "$*" >>"$LOG_FILE"
	"$@" >>"$LOG_FILE" 2>&1 || die "Command failed: $* (see $LOG_FILE)"
}

need_root() {
	[[ ${EUID:-$(id -u)} -eq 0 ]] || die "Must run as root on the Proxmox host."
}

need_host_tools() {
	local missing=() c
	for c in pct pveam pvesm pvesh; do
		command -v "$c" >/dev/null 2>&1 || missing+=("$c")
	done
	((${#missing[@]} == 0)) || die "Missing: ${missing[*]}. This script must run on a Proxmox VE host."
	[[ -d /etc/pve ]] || die "/etc/pve does not exist - this is not a Proxmox VE host."
}

ask_lxc_password() {
	local pass confirm
	[[ -z $CT_PASSWORD && -z $SSH_KEY_FILE && $DRY_RUN -eq 0 ]] || return 0

	if ! read -r -s -p "Set LXC root password (blank = leave unset): " pass </dev/tty; then
		warn "No terminal available; skipping the LXC root password prompt."
		warn "Use --password or --ssh-key for non-interactive installs."
		return 0
	fi
	printf '\n' >&2
	if [[ -z $pass ]]; then
		warn "No LXC root password set. Use 'pct enter' or install an SSH key later."
		return 0
	fi

	if ! read -r -s -p "Confirm LXC root password: " confirm </dev/tty; then
		die "Could not read the password confirmation."
	fi
	printf '\n' >&2
	if [[ $pass != "$confirm" ]]; then
		die "LXC root passwords do not match."
	fi
	CT_PASSWORD=$pass
}

generate_gateway_token() {
	if command -v openssl >/dev/null 2>&1; then
		openssl rand -hex 24
	else
		od -An -N24 -tx1 /dev/urandom | tr -d ' \n'
	fi
}

usage() {
	cat <<EOF
$SCRIPT_NAME $SCRIPT_VERSION - Create an Ubuntu LXC + install OpenClaw on Proxmox VE

USAGE
  ./$SCRIPT_NAME [options]

EXAMPLES
  # Simplest: Ubuntu 24.04 stock template, DHCP, 4GB RAM, 16GB disk
  ./$SCRIPT_NAME

  # "minimal" rootfs (debootstrap): smaller, cleaner, slower (~5-15 minutes)
  ./$SCRIPT_NAME --minimal --ctid 210 --hostname claw --memory 6144 --disk 24

  # Static IP + automated onboarding with an Anthropic API key, Control UI on the LAN
  ./$SCRIPT_NAME --ip 192.168.1.50/24 --gw 192.168.1.1 \\
      --anthropic-key "\$ANTHROPIC_API_KEY" --bind lan

CONTAINER
  --ctid <id>              VMID (default: next free id in the cluster)
  --hostname <name>        container hostname (default: openclaw)
  --cores <n>              vCPU count (default: 2)
  --memory <mb>            RAM in MB (default: 4096, minimum 2048)
  --swap <mb>              swap in MB (default: 512)
  --disk <gb>              rootfs size in GB (default: 16, minimum 8)
  --storage <id>           storage for the rootfs (default: auto-detect)
  --bridge <vmbr>          network bridge (default: first bridge found)
  --ip <dhcp|CIDR>         eth0 address (default: dhcp)
  --gw <ip>                gateway (required when --ip is a CIDR)
  --nameserver <ip>        DNS for the container (default: from the host)
  --password <pass>        root password (default: unset - use 'pct enter' or an SSH key)
  --ssh-key <file>         your public key (repeatable)

UBUNTU / TEMPLATE
  --ubuntu <ver>           Ubuntu release (default: 24.04)
  --ubuntu-codename <c>    codename for --minimal (e.g. noble, jammy)
  --minimal                build the rootfs with debootstrap instead of the stock template
  --mirror <url>           mirror for debootstrap
  --template-storage <id>  storage for the template (default: auto-detect)

OPENCLAW
  --skip-openclaw          only create the container, skip the OpenClaw install
  --bind <mode>            gateway.bind: loopback|lan|tailnet|custom|auto (default: lan)
  --port <port>            gateway port (default: 18789)
  --gateway-token <token>  gateway auth token (default: auto-generated, 48+ hex chars)
  --anthropic-key <key>    non-interactive onboarding with an Anthropic API key
  --openai-key <key>       non-interactive onboarding with an OpenAI API key
  --onboard-extra "<args>" extra args passed straight to 'openclaw onboard'
  A random Gateway auth token is generated for every install. The Gateway is
  configured with the selected bind mode (default: lan) even when no API key is
  supplied, so the Control UI is ready and protected by the token.
  (with no key => Gateway only; run 'openclaw configure' to add a provider)

MISC
  --dry-run                print the plan, create nothing
  --destroy-on-failure     destroy the container if provisioning fails
  --log <file>             log path (default: /var/log/openclaw-lxc-<time>.log)
  -h, --help               show this help

AFTER INSTALL
  pct enter <ctid>                                  # enter the container
  openclaw onboard                                  # configure the AI provider (if no key was passed)
  openclaw dashboard                                # open the Control UI (prints URL + token)
  pct exec <ctid> -- bash -lc 'openclaw gateway status --deep'
EOF
}

show_summary() {
	local ip=${1:-} url hint
	if [[ -n $ip ]]; then
		if [[ $GATEWAY_BIND == "loopback" ]]; then
			url="http://127.0.0.1:${GATEWAY_PORT}  (loopback only)"
			hint="ssh -N -L ${GATEWAY_PORT}:127.0.0.1:${GATEWAY_PORT} root@${ip}"
		else
			url="http://${ip}:${GATEWAY_PORT}"
			hint=""
		fi
	else
		url="http://<container-ip>:${GATEWAY_PORT}"
		hint=""
	fi

	cat <<EOF

=========================================================================
 DONE
=========================================================================
 Container : ${CTID} (${CT_HOSTNAME})
 IP        : ${ip:-none yet (check DHCP/bridge)}
 Control UI: ${url}
 Token     : ${GATEWAY_TOKEN:-run openclaw dashboard}
 Log       : ${LOG_FILE}
EOF
	[[ -n $hint ]] && printf ' SSH tunnel: %s\n' "$hint"

	if ((SKIP_OPENCLAW)); then
		cat <<EOF

 OpenClaw was NOT installed (--skip-openclaw). The container is ready:
   pct enter ${CTID}
EOF
	else
		cat <<EOF

 Next steps:

   # 1. Enter the container
   pct enter ${CTID}

   # 2. Configure an AI provider if you did not pass an API key
   openclaw configure

   # 3. Configure an AI provider if you did not pass an API key
   openclaw configure

   # 4. Check the Gateway
   openclaw gateway status --deep
EOF
	fi

	cat <<EOF

 Security notes:
   - gateway.bind=${GATEWAY_BIND}: the Gateway listens on every interface inside
     the container. It always requires the generated auth token shown above.
     If you expose it beyond the LAN, set gateway.bind=loopback and use a
     Tailscale/SSH tunnel plus a firewall rule on the host.
   - The container is an unprivileged LXC (nesting=1, keyctl=1): Docker works
     inside it, but not everything behaves the same as in a VM.
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
		--gateway-token)      GATEWAY_TOKEN=${2:?}; shift 2 ;;
		--anthropic-key)      PROVIDER="anthropic"; PROVIDER_KEY=${2:?}; shift 2 ;;
		--openai-key)         PROVIDER="openai";    PROVIDER_KEY=${2:?}; shift 2 ;;
		--onboard-extra)      ONBOARD_EXTRA=${2:?}; shift 2 ;;
		--skip-openclaw)      SKIP_OPENCLAW=1; shift ;;
		--dry-run)            DRY_RUN=1; shift ;;
		--destroy-on-failure) DESTROY_ON_FAILURE=1; shift ;;
		--log)                LOG_FILE=${2:?}; shift 2 ;;
		-h|--help)            usage; exit 0 ;;
		*)                    usage >&2; die "Invalid option: $1" ;;
	esac
done

# ------------------------------------------------------------------ validate
[[ $CT_CORES =~ ^[0-9]+$ ]]     || die "--cores must be a number"
[[ $CT_MEMORY =~ ^[0-9]+$ ]]    || die "--memory must be a number (MB)"
[[ $CT_SWAP =~ ^[0-9]+$ ]]      || die "--swap must be a number (MB)"
[[ $CT_DISK =~ ^[0-9]+$ ]]      || die "--disk must be a number (GB)"
[[ $GATEWAY_PORT =~ ^[0-9]+$ ]] || die "--port must be a number"
((CT_MEMORY >= 2048)) || die "--memory must be at least 2048 MB (the Gateway needs a >= 2GB heap)"
((CT_DISK >= 8))      || die "--disk must be at least 8 GB"

case "$GATEWAY_BIND" in
	loopback|lan|tailnet|custom|auto) ;;
	*) die "--bind must be one of: loopback|lan|tailnet|custom|auto" ;;
esac
if [[ -n $GATEWAY_TOKEN && ${#GATEWAY_TOKEN} -lt 24 ]]; then
	die "--gateway-token must be at least 24 characters"
fi

if [[ $CT_IP != "dhcp" ]]; then
	[[ $CT_IP == */* ]] || die "--ip must be 'dhcp' or a CIDR, e.g. 192.168.1.50/24"
	[[ -n $CT_GW ]] || die "--gw is required when --ip is a CIDR"
fi

if [[ -n $SSH_KEY_FILE && ! -r $SSH_KEY_FILE ]]; then
	die "Cannot read SSH key: $SSH_KEY_FILE"
fi
if [[ -n $SSH_KEY_FILE && -n $CT_PASSWORD ]]; then
	die "Choose one: --password or --ssh-key"
fi

# codename map - only releases we are certain about
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
		die "--minimal with Ubuntu $UBUNTU_VER requires --ubuntu-codename (e.g. --ubuntu-codename noble)"
	fi
	UBUNTU_CODENAME=${DEF_CODENAME}
fi

# ------------------------------------------------------------------ detect
ARCH=$(dpkg --print-architecture)
case "$ARCH" in
	amd64) ARCH_TMPL="amd64"; DEF_MIRROR="http://archive.ubuntu.com/ubuntu" ;;
	arm64) ARCH_TMPL="arm64"; DEF_MIRROR="http://ports.ubuntu.com/ubuntu-ports" ;;
	*) die "Unsupported host architecture: $ARCH" ;;
esac
MIRROR=${MIRROR:-$DEF_MIRROR}

detect_bridge() {
	local b=""
	b=$(awk '/^iface[[:space:]]+vmbr[0-9]+[[:space:]]+inet/{print $2; exit}' /etc/network/interfaces 2>/dev/null || true)
	printf '%s\n' "${b:-vmbr0}"
}

choose_storage() { # $1=content, $2..N=preferred storage types
	local content=$1; shift
	local listing hit t
	listing=$(pvesm status --content "$content" 2>/dev/null \
		| awk 'NR>1 && $3=="active"{print $2":"$1}' || true)

	# fallback: read /etc/pve/storage.cfg directly when pvesm returns nothing
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
		warn "No Ubuntu $UBUNTU_VER template in the list yet - running 'pveam update'..."
		pveam update >>"$LOG_FILE" 2>&1 || true
		tmpl=$(find_std_template)
	fi
	[[ -n $tmpl ]] || die "No 'ubuntu-$UBUNTU_VER-standard' template found for $ARCH_TMPL.
       Try: pveam update && pveam available --section system | grep ubuntu
       Or use: --minimal (build with debootstrap)"

	if ((DRY_RUN)); then
		log "[dry-run] would ensure template: $tmpl on '$TMPL_STORAGE'"
		TMPL_VOL="${TMPL_STORAGE}:vztmpl/${tmpl}"
		return 0
	fi

	if pveam list "$TMPL_STORAGE" 2>/dev/null | grep -q "$tmpl"; then
		log "Template already present: $tmpl"
	else
		log "Downloading template: $tmpl -> storage '$TMPL_STORAGE'"
		run pveam download "$TMPL_STORAGE" "$tmpl"
	fi
	TMPL_VOL="${TMPL_STORAGE}:vztmpl/${tmpl}"
}

build_minimal_template() {
	local name out rootdir keyring keyarg=()
	name="ubuntu-${UBUNTU_CODENAME}-minimal_${UBUNTU_VER}_${ARCH_TMPL}.tar.zst"

	out=$(pvesm path "${TMPL_STORAGE}:vztmpl/${name}" 2>/dev/null | tail -n 1 || true)
	[[ -n $out ]] || die "Cannot resolve the template path on '$TMPL_STORAGE'.
       --minimal requires a 'dir' storage (or NFS/CIFS) with 'vztmpl' content."

	if [[ -s $out ]]; then
		log "Minimal rootfs already present: $out"
		TMPL_VOL="${TMPL_STORAGE}:vztmpl/${name}"
		return 0
	fi

	if ((DRY_RUN)); then
		log "[dry-run] would debootstrap $UBUNTU_CODENAME and create: $out"
		TMPL_VOL="${TMPL_STORAGE}:vztmpl/${name}"
		return 0
	fi

	log "Installing debootstrap + ubuntu-keyring on the host"
	run env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
		debootstrap ubuntu-keyring zstd ca-certificates

	rootdir=$(mktemp -d /var/tmp/openclaw-minimal-rootfs.XXXXXX)
	# shellcheck disable=SC2064
	trap "rm -rf '$rootdir'; cleanup" EXIT

	keyring=/usr/share/keyrings/ubuntu-archive-keyring.gpg
	if [[ -r $keyring ]]; then
		keyarg=(--keyring="$keyring")
	fi

	log "debootstrap $UBUNTU_CODENAME ($ARCH) into $rootdir (5-15 minutes)"
	run env DEBIAN_FRONTEND=noninteractive debootstrap \
		--variant=minbase --arch="$ARCH" --components=main,universe \
		"${keyarg[@]}" \
		--include=systemd,systemd-sysv,libpam-systemd,dbus,udev,kmod,ifupdown,isc-dhcp-client,iproute2,iputils-ping,netbase,ca-certificates,curl,gnupg,git,tzdata,locales,procps,psmisc,less,nano,openssh-server,apt-utils,zstd,xz-utils,tar,rsync,unzip \
		"$UBUNTU_CODENAME" "$rootdir" "$MIRROR"

	log "Cleaning up the rootfs"
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
	: >"$rootdir"/etc/machine-id   # let systemd generate a unique machine-id per container
	: >"$rootdir"/etc/hostname

	mkdir -p "$(dirname "$out")"
	log "Packaging rootfs -> $out"
	printf '+ tar | zstd -9 -> %s\n' "$out" >>"$LOG_FILE"
	tar -C "$rootdir" --numeric-owner --xattrs --acls \
		--exclude=./dev/* --exclude=./proc/* --exclude=./sys/* --exclude=./run/* \
		-cf - . | zstd -T0 -9 -q -f -o "$out" >>"$LOG_FILE" 2>&1

	rm -rf "$rootdir"
	trap cleanup EXIT

	[[ -s $out ]] || die "Failed to build the minimal rootfs"
	TMPL_VOL="${TMPL_STORAGE}:vztmpl/${name}"
}

# ------------------------------------------------------------------ payload
write_payload() {
	PAYLOAD_TMP=$(mktemp /tmp/openclaw-provision.XXXXXX.sh)
	cat >"$PAYLOAD_TMP" <<'OPENCLAW_PAYLOAD'
#!/usr/bin/env bash
# Payload executed INSIDE the container (pushed to /root/openclaw-provision.sh)
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

ENV_FILE=/root/.openclaw-provision.env
# shellcheck disable=SC1090
source "$ENV_FILE"

step() { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }

step "apt update + system upgrade"
apt-get update -q
apt-get -y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade

step "Installing base packages"
apt-get -y -q install --no-install-recommends \
	ca-certificates curl git gnupg jq tzdata procps psmisc zstd xz-utils \
	tar unzip rsync less nano openssh-server libatomic1

systemctl enable --now ssh >/dev/null 2>&1 || systemctl enable --now sshd >/dev/null 2>&1 || true

if [[ "${SKIP_OPENCLAW}" == "1" ]]; then
	step "Skipping the OpenClaw install (--skip-openclaw)"
	exit 0
fi

step "Installing OpenClaw (official installer, bootstraps Node.js LTS if missing)"
if command -v openclaw >/dev/null 2>&1; then
	warn "openclaw already installed: $(openclaw --version 2>/dev/null || echo '?')"
else
	curl -fsSL --proto '=https' --tlsv1.2 https://openclaw.ai/install.sh \
		| bash -s -- --no-prompt --no-onboard
fi
hash -r
if ! command -v openclaw >/dev/null 2>&1; then
	echo "openclaw binary not found after install" >&2
	exit 1
fi
echo "openclaw: $(openclaw --version)"
echo "node:     $(node --version)"
echo "npm:      $(npm --version)"

step "Enabling systemd user lingering (Gateway auto-starts after reboot)"
if command -v loginctl >/dev/null 2>&1; then
	loginctl enable-linger root || warn "loginctl enable-linger failed"
	systemctl start user@0.service || warn "could not start user@0.service"
	for ((i = 0; i < 20; i++)); do
		[[ -S /run/user/0/bus ]] && break
		sleep 0.5
	done
	install -d -m 0700 /run/user/0
	export XDG_RUNTIME_DIR=/run/user/0
	export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/0/bus"
	# 'pct enter' does not create a PAM session, so XDG_RUNTIME_DIR is often
	# missing. Add it to both .bashrc (interactive shells) and profile.d (logins).
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
		|| warn "systemd --user (root) not ready yet; the Gateway service may fail to install"
else
	warn "No loginctl - the systemd user service will not auto-start after reboot"
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
	step "Non-interactive onboarding (provider=${PROVIDER}, bind=${GATEWAY_BIND}:${GATEWAY_PORT})"
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
		--gateway-auth token \
		--gateway-token "${GATEWAY_TOKEN}" \
		--install-daemon --daemon-runtime node \
		"${EXTRA[@]}"
	rc=$?
	set -e
	if ((rc != 0)); then
		warn "Non-interactive onboarding failed (exit $rc)."
		warn "The CLI and the container are still fine. Re-run it manually:"
		warn "  pct enter <ctid>   ->   openclaw onboard"
		exit 0
	fi
else
	step "Configuring Gateway without an AI provider (token auth, bind=${GATEWAY_BIND}:${GATEWAY_PORT})"
	openclaw onboard --non-interactive --accept-risk \
		--mode local \
		--auth-choice skip \
		--gateway-bind "${GATEWAY_BIND}" \
		--gateway-port "${GATEWAY_PORT}" \
		--gateway-auth token \
		--gateway-token "${GATEWAY_TOKEN}" \
		--install-daemon --daemon-runtime node \
		--skip-channels --skip-skills --skip-health --skip-ui
	warn "No AI provider is configured yet. Run 'openclaw configure' inside the container."
fi

step "Checking the Gateway"
openclaw gateway status --deep || warn "Gateway is not healthy yet (see: openclaw logs)"

step "Done"
echo "Gateway: bind=${GATEWAY_BIND} port=${GATEWAY_PORT}"
echo "Gateway token: ${GATEWAY_TOKEN}"
echo "Control UI URL:  openclaw dashboard"
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
		printf 'GATEWAY_TOKEN=%q\n' "$GATEWAY_TOKEN"
		printf 'ONBOARD_EXTRA=%q\n' "$ONBOARD_EXTRA"
	} >"$ENV_TMP"
	chmod 0600 "$ENV_TMP"
}

# ------------------------------------------------------------------ main
need_root
need_host_tools
if ! { : >>"$LOG_FILE"; } 2>/dev/null; then
	warn "Cannot write $LOG_FILE, falling back to /tmp"
	LOG_FILE=/tmp/${LOG_FILE##*/}
	: >>"$LOG_FILE"
fi

log "$SCRIPT_NAME $SCRIPT_VERSION  (log: $LOG_FILE)"

CTID=${CTID:-$(next_ctid)}
[[ $CTID =~ ^[0-9]+$ ]] || die "--ctid must be a number"
if pct status "$CTID" >/dev/null 2>&1; then
	die "VMID $CTID already exists. Pick another --ctid."
fi

ask_lxc_password

if [[ -z $TMPL_STORAGE ]]; then
	TMPL_STORAGE=$(choose_storage vztmpl dir nfs cifs cephfs || true)
fi
[[ -n $TMPL_STORAGE ]] || die "No storage with 'vztmpl' content found."

if [[ -z $ROOTFS_STORAGE ]]; then
	ROOTFS_STORAGE=$(choose_storage rootdir lvmthin zfspool btrfs dir || true)
fi
[[ -n $ROOTFS_STORAGE ]] || die "No storage with 'rootdir' content found."

BRIDGE=${BRIDGE:-$(detect_bridge)}

if ((!SKIP_OPENCLAW)) && [[ -z $GATEWAY_TOKEN ]]; then
	GATEWAY_TOKEN=$(generate_gateway_token)
fi

log "Plan: CT $CTID '$CT_HOSTNAME'  ${CT_CORES} vCPU / ${CT_MEMORY}MB RAM / ${CT_DISK}GB"
log "      rootfs=$ROOTFS_STORAGE  template=$TMPL_STORAGE  bridge=$BRIDGE  ip=$CT_IP"
log "      ubuntu=$UBUNTU_VER  mode=$TEMPLATE_MODE  gateway=$GATEWAY_BIND:$GATEWAY_PORT"

if [[ $TEMPLATE_MODE == "minimal" ]]; then
	build_minimal_template
else
	download_standard_template
fi

NET0="name=eth0,bridge=${BRIDGE},ip=${CT_IP}"
if [[ -n $CT_GW ]]; then NET0+=",gw=${CT_GW}"; fi

# shellcheck disable=SC2054  # nesting=1,keyctl=1 is a single token, not two elements
CREATE_ARGS=(
	"$CTID" "$TMPL_VOL"
	--hostname "$CT_HOSTNAME"
	--description "Ubuntu $UBUNTU_VER LXC - OpenClaw Gateway (created by $SCRIPT_NAME $SCRIPT_VERSION)"
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
	log "DRY-RUN - command that would run:"
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

log "Creating container $CTID"
printf '+ pct create %s (password argv redacted)\n' "$CTID" >>"$LOG_FILE"
if ! pct create "${CREATE_ARGS[@]}" >>"$LOG_FILE" 2>&1; then
	die "pct create failed (see $LOG_FILE)"
fi
CREATED_CT=$CTID

log "Starting container"
if ! pct start "$CTID" >>"$LOG_FILE" 2>&1; then
	die "pct start failed (see $LOG_FILE)"
fi

log "Waiting for the container to finish booting"
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
((ready == 1)) || die "Container not ready after 180s (see: pct enter $CTID; journalctl -b)"

ipaddr=$(pct exec "$CTID" -- sh -c "ip -4 -o addr show dev eth0 2>/dev/null | awk '{print \$4}' | cut -d/ -f1" || true)
if [[ -z $ipaddr ]]; then
	warn "eth0 has no IPv4 yet. Check DHCP/bridge '$BRIDGE' with: pct exec $CTID -- ip a"
else
	log "Container IP: $ipaddr"
fi

if ((SKIP_OPENCLAW)); then
	log "Skipping the OpenClaw install as requested (--skip-openclaw)."
	CREATED_CT=""
	show_summary "$ipaddr"
	exit 0
fi

log "Pushing the provisioning payload into the container"
write_payload
write_env_file
pct push "$CTID" "$PAYLOAD_TMP" /root/openclaw-provision.sh --perms 0755 >>"$LOG_FILE" 2>&1 \
	|| die "pct push of the payload failed"
pct push "$CTID" "$ENV_TMP" /root/.openclaw-provision.env --perms 0600 >>"$LOG_FILE" 2>&1 \
	|| die "pct push of the env file failed"

log "Installing OpenClaw inside the container (5-15 minutes, output streamed below)"
if ! pct exec "$CTID" -- /root/openclaw-provision.sh 2>&1 | tee -a "$LOG_FILE"; then
	die "In-container install failed (see $LOG_FILE)"
fi
pct exec "$CTID" -- rm -f /root/.openclaw-provision.env >/dev/null 2>&1 || true

CREATED_CT=""
show_summary "$ipaddr"
