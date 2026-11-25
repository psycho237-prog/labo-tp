#!/usr/bin/env bash
# =============================================================================
#  TP INF3611 — préparation d'un PC CLIENT Linux pour le laboratoire
#
#  Scenario : le PC client et le serveur sont sur le MÊME point d'accès Wi-Fi.
#  Le routeur du point d'accès fournit adresse et Internet ; ce script :
#    1. installe les outils de test du rapport (dig, nmap, tcpdump, iperf3…)
#    2. renouvelle le bail DHCP et vérifie que le PC est sur le réseau du serveur
#    3. teste la chaîne : adresse → ping serveur → DNS → web → ports → débit
#    4. affiche les commandes prêtes à lancer pendant l'exposé
#
#  Usage :
#     sudo SERVER_IP=192.168.43.23 ./setup-client.sh   # installation + tests
#     sudo SERVER_IP=192.168.43.23 ./setup-client.sh --check   # tests seuls
#     sudo CLIENT_IF=wlan0 ./setup-client.sh           # imposer l'interface
#     sudo LAB_NET=10.0.5 ./setup-client.sh            # forcer un autre /24
# =============================================================================
set -euo pipefail

SERVER_IP="${SERVER_IP:-192.168.1.1}"
LAB_NET="${LAB_NET:-${SERVER_IP%.*}}"
CLIENT_IF="${CLIENT_IF:-}"
CHECK_ONLY=0

for arg in "$@"; do
  case "$arg" in
    --check) CHECK_ONLY=1 ;;
    -h|--help)
      sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "Option inconnue : $arg (voir --help)" >&2; exit 2 ;;
  esac
done

info() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[1;32m[ok]\033[0m %s\n' "$*"; }
warn() { printf '    \033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mERREUR :\033[0m %s\n' "$*" >&2; exit 1; }

[ "$CHECK_ONLY" -eq 1 ] || [ "$(id -u)" -eq 0 ] || exec sudo -E bash "$0" "$@"

info "Préparation du PC client — serveur ${SERVER_IP} sur ${LAB_NET}.0/24"

# -----------------------------------------------------------------------------
# 1. Outils de test
# -----------------------------------------------------------------------------
install_tools() {
  # commande testée → paquet Debian/Ubuntu
  local pairs=(
    "ip:iproute2" "dig:dnsutils" "traceroute:traceroute" "mtr:mtr-tiny"
    "nmap:nmap" "tcpdump:tcpdump" "tshark:tshark" "iperf3:iperf3"
    "curl:curl" "nc:netcat-openbsd" "ethtool:ethtool" "lsof:lsof"
    "ssh:openssh-client"
  )
  local missing=() entry cmd pkg
  for entry in "${pairs[@]}"; do
    cmd="${entry%%:*}"
    pkg="${entry##*:}"
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$pkg")
  done

  if [ "${#missing[@]}" -eq 0 ]; then
    ok "tous les outils sont déjà présents"
    return
  fi
  command -v apt-get >/dev/null || { warn "apt absent : installe à la main : ${missing[*]}"; return; }

  info "Installation des outils manquants : ${missing[*]}"
  export DEBIAN_FRONTEND=noninteractive
  echo "wireshark-common wireshark-common/install-setuid boolean false" | debconf-set-selections 2>/dev/null || true
  apt-get update -qq
  apt-get install -y -qq "${missing[@]}" >/dev/null
  ok "outils installés"
}

# -----------------------------------------------------------------------------
# 2. Interface du labo
# -----------------------------------------------------------------------------
pick_if() {
  if [ -n "$CLIENT_IF" ]; then
    ip link show "$CLIENT_IF" >/dev/null 2>&1 || die "interface $CLIENT_IF inconnue (voir 'ip -br link')"
    printf '%s' "$CLIENT_IF"
    return
  fi

  local def cand
  # 1) une interface déjà dans le sous-réseau du serveur
  cand="$(ip -4 -br addr show | awk -v p="${LAB_NET}." 'index($3, p) == 1 {print $1; exit}' | sed 's/@.*//')"
  if [ -n "$cand" ]; then
    printf '%s' "$cand"
    return
  fi

  # 2) l'interface qui porte Internet : sur un PC portable, c'est le Wi-Fi
  def="$(ip route show default 2>/dev/null | awk '/^default/ {print $5; exit}')"
  if [ -n "$def" ]; then
    printf '%s' "$def"
    return
  fi

  # 3) à défaut, la première interface réelle
  cand="$(ip -br link show \
    | awk '$1 != "lo" && $1 !~ /^(veth|docker|br-|virbr|tun|tap|wg|proton|ipv6leak)/ {sub(/@.*/, "", $1); print $1; exit}')"
  [ -n "$cand" ] || die "aucune interface réseau utilisable (voir 'ip -br link')"
  printf '%s' "$cand"
}

has_lab_address() {
  ip -4 -br addr show dev "$1" 2>/dev/null | grep -q " ${LAB_NET}\."
}

# -----------------------------------------------------------------------------
# 3. Bail DHCP auprès du serveur
# -----------------------------------------------------------------------------
configure_dhcp() {
  local iface="$1"

  if has_lab_address "$iface"; then
    ok "$iface a déjà une adresse dans ${LAB_NET}.0/24"
    return
  fi

  info "Demande d'un bail DHCP sur $iface (routeur du point d'accès)"

  if command -v nmcli >/dev/null 2>&1; then
    local con
    con="$(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null \
      | awk -F: -v d="$iface" '$2==d {print $1; exit}')"
    if [ -z "$con" ]; then
      con="$(nmcli -t -f NAME,DEVICE connection show 2>/dev/null \
        | awk -F: -v d="$iface" '$2==d {print $1; exit}')"
      if [ -n "$con" ]; then
        nmcli connection up "$con" >/dev/null 2>&1 || true
      fi
    else
      nmcli connection modify "$con" ipv4.method auto 2>/dev/null || true
      nmcli connection up "$con" >/dev/null 2>&1 || true
    fi
  fi

  if ! has_lab_address "$iface"; then
    if command -v dhclient >/dev/null 2>&1; then
      dhclient -r "$iface" >/dev/null 2>&1 || true
      timeout 20 dhclient -1 "$iface" >/dev/null 2>&1 || true
    elif command -v udhcpc >/dev/null 2>&1; then
      timeout 20 udhcpc -i "$iface" -q -n >/dev/null 2>&1 || true
    fi
  fi

  if has_lab_address "$iface"; then
    ok "$(ip -4 -br addr show dev "$iface" | awk '{print $3}') sur $iface"
    ok "passerelle : $(ip route show default | awk '/^default/ {print $3; exit}')"
  else
    warn "aucune adresse en ${LAB_NET}.x obtenue sur $iface"
    warn "vérifie : câble/switch, serveur allumé, DHCP actif (sudo systemctl status dnsmasq)"
    warn "essai manuel : sudo dhclient -v $iface"
  fi
}

# -----------------------------------------------------------------------------
# 4. Vérifications
# -----------------------------------------------------------------------------
PASS=0
FAIL=0

check() { # check <libellé> <commande…>
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    printf '    \033[1;32m[OK]\033[0m    %s\n' "$label"
    PASS=$((PASS + 1))
  else
    printf '    \033[1;31m[ÉCHEC]\033[0m %s\n' "$label"
    FAIL=$((FAIL + 1))
  fi
}

note() { printf '    \033[1;33m[info]\033[0m  %s\n' "$*"; }

run_checks() {
  local iface="$1"

  info "Vérifications depuis ce PC"

  if has_lab_address "$iface"; then
    printf '    \033[1;32m[OK]\033[0m    adresse %s dans %s.0/24\n' \
      "$(ip -4 -br addr show dev "$iface" | awk '{print $3}')" "$LAB_NET"
    PASS=$((PASS + 1))
  else
    printf '    \033[1;31m[ÉCHEC]\033[0m pas d’adresse dans %s.0/24 sur %s\n' "$LAB_NET" "$iface"
    FAIL=$((FAIL + 1))
  fi

  check "même sous-réseau que le serveur (${LAB_NET}.0/24)" \
    bash -c "ip -4 -br addr | grep -q ' ${LAB_NET}\\.'"
  check "ping $SERVER_IP" ping -c 2 -W 2 "$SERVER_IP"
  note "passerelle utilisée : $(ip route show default 2>/dev/null | awk '/^default/ {print $3; exit}')"

  if command -v dig >/dev/null 2>&1; then
    check "DNS du labo : web.tp.local → ${SERVER_IP}" \
      bash -c "dig +short +time=2 +tries=1 web.tp.local @${SERVER_IP} | grep -qx '${SERVER_IP}'"
  fi
  check "port 443 ouvert (nc)" nc -zv -w 3 "$SERVER_IP" 443
  check "HTTPS répond (curl -k)" \
    curl -skI --max-time 5 -H 'Host: web.tp.local' "https://${SERVER_IP}/"
  if command -v iperf3 >/dev/null 2>&1; then
    check "débit iperf3 (3 s)" timeout 15 iperf3 -c "$SERVER_IP" -t 3
  fi

  # informatifs : dépendent du NAT / de l'accès Internet du serveur
  if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
    note "Internet OK (NAT du serveur actif)"
  else
    note "pas d’accès Internet : normal si le labo est isolé (UPLINK_IF= à l'installation)"
  fi
  if command -v traceroute >/dev/null 2>&1; then
    note "chemin : $(traceroute -n -w 1 -q 1 -m 3 "$SERVER_IP" 2>/dev/null | head -2 | tr '\n' ' ')"
  fi
}

# -----------------------------------------------------------------------------
# Déroulé
# -----------------------------------------------------------------------------
IFACE="$(pick_if)"
info "Interface du labo : $IFACE"

if [ "$CHECK_ONLY" -eq 0 ]; then
  install_tools
  configure_dhcp "$IFACE"
else
  note "mode --check : aucun paquet installé, aucun bail demandé"
fi

run_checks "$IFACE"

if [ "$FAIL" -eq 0 ]; then
  TITLE="PC CLIENT PRÊT"
else
  TITLE="PC CLIENT — BILAN (des échecs subsistent)"
fi

cat <<EOF

=======================================================================
 $TITLE  (interface $IFACE — serveur ${SERVER_IP})
=======================================================================
 Adresse : $(ip -4 -br addr show dev "$IFACE" 2>/dev/null | awk '{print $3}')
 Route   : $(ip route show default 2>/dev/null | head -1)

 Commandes de démonstration
   ip -br addr && ip route
   ping -c 4 ${SERVER_IP}
   dig +short web.tp.local @${SERVER_IP}
   curl -kI -H 'Host: web.tp.local' https://${SERVER_IP}/
   nc -zv ${SERVER_IP} 443
   nmap -sn ${LAB_NET}.0/24
   traceroute -n 8.8.8.8
   iperf3 -c ${SERVER_IP} -t 10
   ssh tp@${SERVER_IP}
   scp tp@${SERVER_IP}:/var/www/tp-lab/fichier-20m.bin .

 Résultat : ${PASS} OK / ${FAIL} échec(s)
EOF

[ "$FAIL" -eq 0 ] || {
  echo
  echo "Corrige les échecs ci-dessus avant la démonstration (voir README, §5 Dépannage)."
  exit 1
}
