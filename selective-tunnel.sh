#!/usr/bin/env bash
#
# selective-tunnel.sh
# -------------------------------------------------------------------
# Route ONLY specific domains from an OpenVPN server out through a
# second server via a WireGuard tunnel (policy-based routing).
#
# All other traffic keeps using the OpenVPN server's main IP.
#
# Works on Debian/Ubuntu (apt) and RHEL-family (dnf/yum).
# Run as root.  Re-run any time to manage domains.
# -------------------------------------------------------------------

set -euo pipefail

# ------------------------- constants -------------------------------
WG_IF="wg0"
RT_TABLE="200"
FWMARK="0x1"
STATE_DIR="/etc/selective-routing"
PARAMS_FILE="${STATE_DIR}/params"
DOMAINS_FILE="${STATE_DIR}/domains.list"
DNSMASQ_CONF="/etc/dnsmasq.d/selective.conf"
WG_CONF="/etc/wireguard/${WG_IF}.conf"
IPSET_NAME="routed"
IPSET_SERVICE="/etc/systemd/system/ipset-${IPSET_NAME}.service"

# Default domains shipped with the script (edit freely).
DEFAULT_DOMAINS=(
  # IP-check test sites
  whatismyipaddress.com iplocation.net
  # Google (search, accounts, developer, Gemini, AI Studio, Labs/Flow) + CDNs
  google.com google.dev googleapis.com gstatic.com googleusercontent.com ggpht.com
  labs.google withgoogle.com android.com gvt1.com gvt2.com
  # Grok (xAI)
  grok.com x.ai
  # Anthropic Claude
  claude.ai anthropic.com
  # OpenAI ChatGPT + CDNs
  openai.com chatgpt.com oaistatic.com oaiusercontent.com
)

RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[0;33m'; NC='\033[0m'
say()  { echo -e "${GRN}[*]${NC} $*"; }
warn() { echo -e "${YLW}[!]${NC} $*"; }
err()  { echo -e "${RED}[x]${NC} $*" >&2; }

# ------------------------- helpers ---------------------------------
require_root() {
  if [[ ${EUID} -ne 0 ]]; then err "Please run as root."; exit 1; fi
}

pkg_install() {
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y "$@"
  elif command -v yum >/dev/null 2>&1; then
    yum install -y "$@"
  else
    err "No supported package manager (apt/dnf/yum) found."; exit 1
  fi
}

detect_env() {
  # Internet-facing NIC (default route)
  PUB_NIC="$(ip -4 route ls | awk '/^default/{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
  # OpenVPN tun interface that has an IPv4 address
  TUN_IF="$(ip -o -4 addr show | awk '$2 ~ /^tun/ {print $2; exit}')"
  if [[ -z "${TUN_IF}" ]]; then
    TUN_IF="$(ip -o link show | awk -F': ' '$2 ~ /^tun/ {print $2; exit}')"
  fi
  if [[ -n "${TUN_IF}" ]]; then
    TUN_GW="$(ip -o -4 addr show dev "${TUN_IF}" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"
  fi
}

parse_field() {
  # $1 = key name, reads from $CLIENT_CONF
  printf '%s\n' "${CLIENT_CONF}" \
    | grep -iE "^[[:space:]]*$1[[:space:]]*=" | head -1 \
    | sed -E "s/^[^=]*=[[:space:]]*//" | sed -E "s/[[:space:]]*(#.*)?$//"
}

read_client_conf() {
  echo ""
  echo "Provide the WireGuard CLIENT config generated on the second server"
  echo "(the file like /root/wg0-client-*.conf from the angristan script)."
  echo ""
  read -rp "Path to client .conf file (leave empty to paste it): " CPATH
  if [[ -n "${CPATH}" ]]; then
    if [[ ! -f "${CPATH}" ]]; then err "File not found: ${CPATH}"; exit 1; fi
    CLIENT_CONF="$(cat "${CPATH}")"
  else
    echo ""
    echo ">>> Paste the FULL client config now, then press ENTER and Ctrl-D:"
    CLIENT_CONF="$(cat)"
  fi

  CLIENT_PRIV_KEY="$(parse_field PrivateKey)"
  local addr; addr="$(parse_field Address)"
  CLIENT_V4="$(printf '%s' "${addr}" | tr ',' '\n' | grep -E '^[0-9]+\.' | head -1)"
  CLIENT_V4_IP="${CLIENT_V4%%/*}"
  SERVER_PUB_KEY="$(parse_field PublicKey)"
  PSK="$(parse_field PresharedKey)"
  ENDPOINT="$(parse_field Endpoint)"

  if [[ -z "${CLIENT_PRIV_KEY}" || -z "${CLIENT_V4_IP}" || -z "${SERVER_PUB_KEY}" || -z "${ENDPOINT}" ]]; then
    err "Could not parse the client config. Required: PrivateKey, Address, PublicKey, Endpoint."
    exit 1
  fi

  # Derive the WireGuard subnet (e.g. 10.66.66.2 -> 10.66.66.0/24)
  local base; base="$(echo "${CLIENT_V4_IP}" | awk -F. '{print $1"."$2"."$3}')"
  WG_SUBNET="${base}.0/24"

  echo ""
  say "Parsed WireGuard client config:"
  echo "    Client address : ${CLIENT_V4_IP}  (subnet ${WG_SUBNET})"
  echo "    Server pubkey  : ${SERVER_PUB_KEY}"
  echo "    PSK            : $([[ -n "${PSK}" ]] && echo present || echo none)"
  echo "    Endpoint       : ${ENDPOINT}"
  echo ""
  read -rp "Looks correct? Press ENTER to continue (or Ctrl-C to abort)... " _
}

write_params() {
  mkdir -p "${STATE_DIR}"
  cat > "${PARAMS_FILE}" <<EOF
WG_IF=${WG_IF}
RT_TABLE=${RT_TABLE}
FWMARK=${FWMARK}
PUB_NIC=${PUB_NIC}
TUN_IF=${TUN_IF}
TUN_GW=${TUN_GW}
WG_SUBNET=${WG_SUBNET}
ENDPOINT=${ENDPOINT}
EOF
  chmod 600 "${PARAMS_FILE}"
}

write_wg_conf() {
  mkdir -p /etc/wireguard
  cat > "${WG_CONF}" <<EOF
[Interface]
PrivateKey = ${CLIENT_PRIV_KEY}
Address = ${CLIENT_V4_IP}/32
Table = off

# --- selective routing setup (only ipset "${IPSET_NAME}" goes via tunnel) ---
PostUp = ip route add ${WG_SUBNET} dev ${WG_IF}
PostUp = ip route add default dev ${WG_IF} table ${RT_TABLE}
PostUp = ip rule add fwmark ${FWMARK} table ${RT_TABLE}
PostUp = iptables -t mangle -A PREROUTING -i ${TUN_IF} -m set --match-set ${IPSET_NAME} dst -j MARK --set-mark ${FWMARK}
PostUp = iptables -t nat -A POSTROUTING -o ${WG_IF} -j MASQUERADE
PostUp = iptables -A FORWARD -i ${TUN_IF} -o ${WG_IF} -j ACCEPT
PostUp = iptables -A FORWARD -i ${WG_IF} -o ${TUN_IF} -j ACCEPT
PostUp = iptables -t nat -A PREROUTING -i ${TUN_IF} -p udp --dport 53 -j REDIRECT --to-ports 53
PostUp = iptables -t nat -A PREROUTING -i ${TUN_IF} -p tcp --dport 53 -j REDIRECT --to-ports 53

PostDown = ip route del ${WG_SUBNET} dev ${WG_IF} || true
PostDown = ip rule del fwmark ${FWMARK} table ${RT_TABLE} || true
PostDown = ip route flush table ${RT_TABLE} || true
PostDown = iptables -t mangle -D PREROUTING -i ${TUN_IF} -m set --match-set ${IPSET_NAME} dst -j MARK --set-mark ${FWMARK} || true
PostDown = iptables -t nat -D POSTROUTING -o ${WG_IF} -j MASQUERADE || true
PostDown = iptables -D FORWARD -i ${TUN_IF} -o ${WG_IF} -j ACCEPT || true
PostDown = iptables -D FORWARD -i ${WG_IF} -o ${TUN_IF} -j ACCEPT || true
PostDown = iptables -t nat -D PREROUTING -i ${TUN_IF} -p udp --dport 53 -j REDIRECT --to-ports 53 || true
PostDown = iptables -t nat -D PREROUTING -i ${TUN_IF} -p tcp --dport 53 -j REDIRECT --to-ports 53 || true

[Peer]
PublicKey = ${SERVER_PUB_KEY}
$( [[ -n "${PSK}" ]] && echo "PresharedKey = ${PSK}" )
Endpoint = ${ENDPOINT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
  chmod 600 "${WG_CONF}"
}

write_ipset_service() {
  cat > "${IPSET_SERVICE}" <<EOF
[Unit]
Description=Create ipset for selective routing (${IPSET_NAME})
Before=wg-quick@${WG_IF}.service dnsmasq.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/ipset create ${IPSET_NAME} hash:ip family inet -exist
ExecStop=/sbin/ipset destroy ${IPSET_NAME}

[Install]
WantedBy=multi-user.target
EOF

  mkdir -p "/etc/systemd/system/wg-quick@${WG_IF}.service.d" \
           "/etc/systemd/system/dnsmasq.service.d"
  printf '[Unit]\nAfter=ipset-%s.service\nRequires=ipset-%s.service\n' "${IPSET_NAME}" "${IPSET_NAME}" \
    > "/etc/systemd/system/wg-quick@${WG_IF}.service.d/override.conf"
  printf '[Unit]\nAfter=ipset-%s.service\nRequires=ipset-%s.service\n' "${IPSET_NAME}" "${IPSET_NAME}" \
    > "/etc/systemd/system/dnsmasq.service.d/override.conf"
}

generate_dnsmasq() {
  # Rebuilds the dnsmasq config from ${DOMAINS_FILE}
  {
    echo "# Managed by selective-tunnel.sh - do not edit by hand."
    echo "interface=${TUN_IF}"
    echo "listen-address=${TUN_GW}"
    echo "bind-interfaces"
    echo "no-resolv"
    echo "server=1.1.1.1"
    echo "server=1.0.0.1"
    echo ""
    while IFS= read -r d; do
      [[ -z "${d}" || "${d}" =~ ^# ]] && continue
      echo "ipset=/${d}/${IPSET_NAME}"
    done < "${DOMAINS_FILE}"
  } > "${DNSMASQ_CONF}"
}

seed_default_domains() {
  mkdir -p "${STATE_DIR}"
  if [[ ! -f "${DOMAINS_FILE}" ]]; then
    printf '%s\n' "${DEFAULT_DOMAINS[@]}" | grep -vE '^\s*#' | sort -u > "${DOMAINS_FILE}"
  fi
}

populate_domain() {
  # Resolve a domain through local dnsmasq so ipset fills immediately
  local d="$1"
  if command -v dig >/dev/null 2>&1; then
    dig +short +time=3 +tries=1 "${d}" @"${TUN_GW}" >/dev/null 2>&1 || true
    dig +short +time=3 +tries=1 "www.${d}" @"${TUN_GW}" >/dev/null 2>&1 || true
  fi
}

enable_forwarding() {
  echo 'net.ipv4.ip_forward = 1' > /etc/sysctl.d/99-selective-tunnel.conf
  sysctl -p /etc/sysctl.d/99-selective-tunnel.conf >/dev/null 2>&1 || true
}

# --------------------------- actions -------------------------------
do_install() {
  detect_env
  echo ""
  say "Detected environment:"
  echo "    Internet NIC   : ${PUB_NIC:-<none>}"
  echo "    OpenVPN tun    : ${TUN_IF:-<none>}  gateway ${TUN_GW:-<none>}"
  if [[ -z "${TUN_IF}" || -z "${TUN_GW}" || -z "${PUB_NIC}" ]]; then
    warn "Could not fully auto-detect. Please enter values manually."
    read -rp "Internet NIC [${PUB_NIC}]: " x; PUB_NIC="${x:-$PUB_NIC}"
    read -rp "OpenVPN tun interface [${TUN_IF}]: " x; TUN_IF="${x:-$TUN_IF}"
    read -rp "OpenVPN tun gateway IP [${TUN_GW}]: " x; TUN_GW="${x:-$TUN_GW}"
  fi
  [[ -z "${TUN_IF}" || -z "${TUN_GW}" || -z "${PUB_NIC}" ]] && { err "Missing network info."; exit 1; }

  read_client_conf

  say "Installing packages..."
  pkg_install wireguard wireguard-tools ipset dnsmasq dnsutils 2>/dev/null \
    || pkg_install wireguard-tools ipset dnsmasq bind-utils

  enable_forwarding
  seed_default_domains
  write_params
  write_wg_conf
  write_ipset_service
  generate_dnsmasq

  say "Enabling services..."
  systemctl daemon-reload
  systemctl enable --now "ipset-${IPSET_NAME}.service"
  systemctl restart dnsmasq
  systemctl enable dnsmasq
  systemctl enable "wg-quick@${WG_IF}" >/dev/null 2>&1 || true
  # (re)start the tunnel cleanly
  systemctl stop "wg-quick@${WG_IF}" >/dev/null 2>&1 || true
  systemctl start "wg-quick@${WG_IF}"

  say "Pre-resolving default domains to populate the ipset..."
  while IFS= read -r d; do
    [[ -z "${d}" || "${d}" =~ ^# ]] && continue
    populate_domain "${d}"
  done < "${DOMAINS_FILE}"

  echo ""
  say "Done! Tunnel + selective routing is active."
  do_status
}

load_params() {
  if [[ ! -f "${PARAMS_FILE}" ]]; then
    err "Not installed yet. Run the install option first."; return 1
  fi
  # shellcheck disable=SC1090
  source "${PARAMS_FILE}"
}

do_add_domain() {
  load_params || return 1
  echo ""
  read -rp "Enter domain(s) to ADD (space separated, e.g. netflix.com spotify.com): " -a NEW
  [[ ${#NEW[@]} -eq 0 ]] && { warn "Nothing entered."; return; }
  for d in "${NEW[@]}"; do
    d="$(echo "${d}" | sed -E 's#^https?://##; s#/.*$##; s/[[:space:]]//g')"
    [[ -z "${d}" ]] && continue
    if grep -qxF "${d}" "${DOMAINS_FILE}" 2>/dev/null; then
      warn "${d} already present."
    else
      echo "${d}" >> "${DOMAINS_FILE}"
      say "Added ${d}"
    fi
  done
  sort -u -o "${DOMAINS_FILE}" "${DOMAINS_FILE}"
  generate_dnsmasq
  systemctl restart dnsmasq
  for d in "${NEW[@]}"; do
    d="$(echo "${d}" | sed -E 's#^https?://##; s#/.*$##; s/[[:space:]]//g')"
    [[ -n "${d}" ]] && populate_domain "${d}"
  done
  say "dnsmasq updated & restarted. New domains are now routed via the tunnel."
}

do_remove_domain() {
  load_params || return 1
  echo ""
  echo "Current domains:"
  nl -w2 -s') ' "${DOMAINS_FILE}"
  echo ""
  read -rp "Enter domain(s) to REMOVE (space separated): " -a DEL
  [[ ${#DEL[@]} -eq 0 ]] && { warn "Nothing entered."; return; }
  for d in "${DEL[@]}"; do
    d="$(echo "${d}" | sed -E 's#^https?://##; s#/.*$##; s/[[:space:]]//g')"
    if grep -qxF "${d}" "${DOMAINS_FILE}" 2>/dev/null; then
      grep -vxF "${d}" "${DOMAINS_FILE}" > "${DOMAINS_FILE}.tmp" && mv "${DOMAINS_FILE}.tmp" "${DOMAINS_FILE}"
      say "Removed ${d}"
    else
      warn "${d} not found."
    fi
  done
  generate_dnsmasq
  systemctl restart dnsmasq
  # Flush stale IPs; active domains refill on next lookup.
  ipset flush "${IPSET_NAME}" 2>/dev/null || true
  say "dnsmasq updated & restarted. Removed domains now use the main IP again."
}

do_list() {
  load_params || return 1
  echo ""
  echo "Routed domains (${DOMAINS_FILE}):"
  nl -w2 -s') ' "${DOMAINS_FILE}"
  echo ""
  echo "IPs currently in ipset '${IPSET_NAME}': $(ipset list ${IPSET_NAME} 2>/dev/null | grep -c '^[0-9]')"
}

do_list_inline() {
  load_params || return 1
  echo ""
  # One space-separated line, no numbers — easy to copy.
  grep -vE '^\s*(#|$)' "${DOMAINS_FILE}" | paste -sd' ' -
  echo ""
}

do_status() {
  load_params || return 1
  echo ""
  echo "================ STATUS ================"
  echo "-- WireGuard (${WG_IF}) --"
  wg show "${WG_IF}" 2>/dev/null || warn "wg interface not up"
  echo ""
  echo "-- Services --"
  for s in "ipset-${IPSET_NAME}.service" "wg-quick@${WG_IF}.service" dnsmasq.service; do
    printf "%-35s %s\n" "${s}" "$(systemctl is-active "${s}" 2>/dev/null)"
  done
  echo ""
  echo "-- ipset entries: $(ipset list ${IPSET_NAME} 2>/dev/null | grep -c '^[0-9]') --"
  echo ""
  echo "-- Route test --"
  local ep_ip; ep_ip="${ENDPOINT%%:*}"
  local one; one="$(ipset list ${IPSET_NAME} 2>/dev/null | grep -m1 '^[0-9]')"
  if [[ -n "${one}" ]]; then
    echo "Target IP ${one} (marked): $(ip route get "${one}" mark ${FWMARK} 2>/dev/null | head -1)"
    echo "Same IP  ${one} (normal): $(ip route get "${one}" 2>/dev/null | head -1)"
  fi
  echo "Tunnel exit server: ${ep_ip}"
  echo "======================================="
}

is_ipv4() {
  local ip="$1"
  [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local IFS=.
  local -a oct=($ip)
  local x
  for x in "${oct[@]}"; do
    (( x >= 0 && x <= 255 )) || return 1
  done
  return 0
}

do_change_endpoint() {
  load_params || return 1
  if [[ ! -f "${WG_CONF}" ]]; then
    err "WireGuard config not found: ${WG_CONF}"; return 1
  fi

  local current="${ENDPOINT:-}"
  if [[ -z "${current}" ]]; then
    current="$(grep -iE '^[[:space:]]*Endpoint[[:space:]]*=' "${WG_CONF}" | head -1 \
      | sed -E 's/^[^=]*=[[:space:]]*//; s/[[:space:]]*(#.*)?$//')"
  fi
  if [[ -z "${current}" ]]; then
    err "Could not determine the current endpoint."; return 1
  fi

  local current_ip="${current%%:*}"
  local current_port="${current##*:}"
  if [[ "${current_ip}" == "${current_port}" || -z "${current_port}" ]]; then
    current_port="51820"
  fi

  echo ""
  say "Current WireGuard destination: ${current}"
  echo "Keys stay unchanged; only the server IP is updated."
  echo ""
  read -rp "New server IP (port stays ${current_port}), or IP:PORT: " new
  new="$(printf '%s' "${new}" | tr -d '[:space:]')"
  [[ -z "${new}" ]] && { warn "Nothing entered."; return; }

  local new_ip new_port new_endpoint
  if [[ "${new}" == *:* ]]; then
    new_ip="${new%%:*}"
    new_port="${new##*:}"
  else
    new_ip="${new}"
    new_port="${current_port}"
  fi

  if ! is_ipv4 "${new_ip}"; then
    err "Invalid IPv4 address: ${new_ip}"; return 1
  fi
  if ! [[ "${new_port}" =~ ^[0-9]+$ ]] || (( new_port < 1 || new_port > 65535 )); then
    err "Invalid port: ${new_port}"; return 1
  fi
  new_endpoint="${new_ip}:${new_port}"

  if [[ "${new_endpoint}" == "${current}" ]]; then
    warn "Endpoint is already ${current}. Nothing to do."
    return
  fi

  echo ""
  echo "    ${current}  ->  ${new_endpoint}"
  read -rp "Apply and reconnect to the new server? [y/N]: " c
  [[ "${c}" =~ ^[yY]$ ]] || { echo "Aborted."; return; }

  # Persist in wg.conf so the change survives reboots/restarts.
  sed -i -E "s|^[[:space:]]*Endpoint[[:space:]]*=.*|Endpoint = ${new_endpoint}|" "${WG_CONF}"
  if ! grep -qE "^[[:space:]]*Endpoint[[:space:]]*=[[:space:]]*${new_endpoint}[[:space:]]*$" "${WG_CONF}"; then
    err "Failed to update Endpoint in ${WG_CONF}"; return 1
  fi

  ENDPOINT="${new_endpoint}"
  write_params

  say "Restarting WireGuard to connect to ${new_endpoint}..."
  systemctl restart "wg-quick@${WG_IF}.service"

  echo ""
  say "Destination updated. Waiting briefly for handshake..."
  sleep 2
  do_status
}

do_restart() {
  load_params || return 1
  say "Restarting selective-routing services..."
  # Ensure the ipset exists (do NOT restart its service: destroying an
  # in-use set fails while WireGuard's iptables rule references it).
  systemctl start "ipset-${IPSET_NAME}.service" 2>/dev/null || true
  systemctl restart "wg-quick@${WG_IF}.service"
  systemctl restart dnsmasq
  say "Re-populating ipset from domain list..."
  if [[ -f "${DOMAINS_FILE}" ]]; then
    while IFS= read -r d; do
      [[ -z "${d}" || "${d}" =~ ^# ]] && continue
      populate_domain "${d}"
    done < "${DOMAINS_FILE}"
  fi
  say "Services restarted."
  do_status
}

do_uninstall() {
  load_params || return 1
  echo ""
  warn "This removes the tunnel + selective routing (OpenVPN itself is untouched)."
  read -rp "Type 'yes' to proceed: " c
  [[ "${c}" != "yes" ]] && { echo "Aborted."; return; }
  systemctl disable --now "wg-quick@${WG_IF}" 2>/dev/null || true
  systemctl disable --now "ipset-${IPSET_NAME}.service" 2>/dev/null || true
  rm -f "${WG_CONF}" "${IPSET_SERVICE}" "${DNSMASQ_CONF}"
  rm -f "/etc/systemd/system/wg-quick@${WG_IF}.service.d/override.conf"
  rm -f "/etc/systemd/system/dnsmasq.service.d/override.conf"
  rm -f /etc/sysctl.d/99-selective-tunnel.conf
  systemctl daemon-reload
  systemctl restart dnsmasq 2>/dev/null || true
  ipset destroy "${IPSET_NAME}" 2>/dev/null || true
  rm -rf "${STATE_DIR}"
  say "Uninstalled selective routing. (WireGuard/dnsmasq packages left installed.)"
}

# ---------------------------- menu ---------------------------------
menu() {
  echo ""
  echo "==========================================================="
  echo "     Selective Tunnel Manager (OpenVPN -> WireGuard)"
  echo "==========================================================="
  if [[ -f "${PARAMS_FILE}" ]]; then
    echo -e "  Status: ${GRN}installed${NC}"
  else
    echo -e "  Status: ${YLW}not installed${NC}"
  fi
  echo "-----------------------------------------------------------"
  echo "  1) Install & configure tunnel routing"
  echo "  2) Add domain(s)"
  echo "  3) Remove domain(s)"
  echo "  4) List routed domains"
  echo "  5) Print domains (one line)"
  echo "  6) Show status / test"
  echo "  7) Change WireGuard server IP"
  echo "  8) Restart services"
  echo "  9) Uninstall"
  echo " 10) Exit"
  echo "-----------------------------------------------------------"
  read -rp "Select an option [1-10]: " opt
  case "${opt}" in
    1) do_install ;;
    2) do_add_domain ;;
    3) do_remove_domain ;;
    4) do_list ;;
    5) do_list_inline ;;
    6) do_status ;;
    7) do_change_endpoint ;;
    8) do_restart ;;
    9) do_uninstall ;;
    10) exit 0 ;;
    *) warn "Invalid option." ;;
  esac
}

# ---------------------------- main ---------------------------------
require_root
while true; do
  menu
done
