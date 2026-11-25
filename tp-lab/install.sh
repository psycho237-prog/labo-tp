#!/usr/bin/env bash
# =============================================================================
#  TP INF3611 — « Les commandes avancées réseau » — Groupe 12
#  Provisionnement du SERVEUR de laboratoire (Linux : Debian / Ubuntu / Mint)
#
#  Deux modes de déploiement :
#
#    shared  (défaut sur Wi-Fi) : tous les PC, serveur compris, sont sur le
#            MÊME point d'accès. Le routeur du point d'accès fournit DHCP et
#            Internet ; le serveur n'est PAS passerelle, il n'apporte que les
#            services : DNS tp.local, web 80/443, SSH, iperf3, cibles nmap.
#
#    gateway : le serveur EST la passerelle + DHCP d'un labo câblé isolé
#            (deux cartes réseau : LAB_IF pour le labo, UPLINK_IF pour Internet).
#
#  Usage :
#     sudo ./install.sh                                # Wi-Fi partagé (mode shared)
#     sudo LAB_IF=eth0 UPLINK_IF=wlan0 ./install.sh    # passerelle câblée + NAT
#     sudo MODE=gateway LAB_IF=eth0 UPLINK_IF= ./install.sh   # labo câblé isolé
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG="$HERE/config"

# ---- Paramètres (surcharger par variables d'environnement) ------------------
MODE="${MODE:-auto}"              # auto | shared | gateway
LAB_IF="${LAB_IF:-}"              # interface côté labo (Wi-Fi du point d'accès, ou eth0)
LAB_NET="${LAB_NET:-}"            # déduit de l'interface en mode shared
SERVER_IP="${SERVER_IP:-}"        # déduite de l'interface en mode shared
UPLINK_IF="${UPLINK_IF:-}"        # gateway seulement : interface Internet (vide = isolé)
UPLINK_IF_GIVEN=0
[ -n "${UPLINK_IF+x}" ] && UPLINK_IF_GIVEN=1
TP_USER="${TP_USER:-tp}"          # compte de démonstration SSH/SCP
TP_PASSWORD="${TP_PASSWORD:-tp2026}"
ENABLE_UFW="${ENABLE_UFW:-1}"
ENABLE_DHCP="${ENABLE_DHCP:-}"    # vide = automatique selon le mode
ENABLE_NAT="${ENABLE_NAT:-}"      # vide = automatique selon le mode

WEB_ROOT="/var/www/tp-lab"
CERT_DIR="/etc/ssl/tp-lab"

# ---- Couleurs / helpers -----------------------------------------------------
info() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[1;32m[ok]\033[0m %s\n' "$*"; }
warn() { printf '    \033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mERREUR :\033[0m %s\n' "$*" >&2; exit 1; }

# =============================================================================
# 0. Contrôles préalables
# =============================================================================
[ "$(id -u)" -eq 0 ] || die "Lance ce script avec sudo :  sudo $0"
command -v apt-get >/dev/null || die "Distribution non Debian/Ubuntu : adapte la liste des paquets."

. /etc/os-release 2>/dev/null || true
info "Serveur de TP — ${PRETTY_NAME:-Linux inconnu}"

default_if() {
  ip route show default 2>/dev/null | awk '/^default/ {print $5; exit}'
}

is_wireless() {
  [ -d "/sys/class/net/$1/wireless" ]
}

# --- Interface du labo --------------------------------------------------------
if [ -z "$LAB_IF" ]; then
  LAB_IF="$(default_if || true)"
  [ -n "$LAB_IF" ] || die "Aucune interface active. Indique-la : sudo LAB_IF=wlan0 $0
Interfaces disponibles :
$(ip -br link)"
  warn "Interface détectée automatiquement : $LAB_IF  (surcharge avec LAB_IF=…)"
fi
ip link show "$LAB_IF" >/dev/null 2>&1 || die "L'interface $LAB_IF n'existe pas (voir 'ip -br link')."
export LAB_IF

# --- Mode de déploiement ------------------------------------------------------
if [ "$MODE" = "auto" ]; then
  if is_wireless "$LAB_IF"; then
    MODE=shared
  elif [ "$UPLINK_IF_GIVEN" = "1" ] && [ -z "$UPLINK_IF" ]; then
    MODE=gateway
  elif [ -z "$UPLINK_IF" ] || [ "$UPLINK_IF" = "$LAB_IF" ]; then
    MODE=shared
  else
    MODE=gateway
  fi
fi
case "$MODE" in
  shared|gateway) ;;
  *) die "MODE doit valoir auto, shared ou gateway." ;;
esac

if [ "$MODE" = "shared" ]; then
  ENABLE_DHCP=0
  ENABLE_NAT=0
  UPLINK_IF=""
else
  ENABLE_DHCP="${ENABLE_DHCP:-1}"
  [ -n "$ENABLE_NAT" ] || ENABLE_NAT=1
  [ "$UPLINK_IF_GIVEN" = "1" ] || UPLINK_IF="$(default_if || true)"
  if [ -z "$UPLINK_IF" ] || [ "$UPLINK_IF" = "$LAB_IF" ]; then
    ENABLE_NAT=0
    UPLINK_IF=""
  fi
fi

# --- Adresse et sous-réseau ---------------------------------------------------
if [ "$MODE" = "shared" ]; then
  CUR_ADDR="$(ip -4 -br addr show dev "$LAB_IF" | awk '{print $3; exit}')"
  [ -n "$CUR_ADDR" ] || die "L'interface $LAB_IF n'a pas d'adresse IPv4 :
connecte ce PC au point d'accès Wi-Fi (ou lance un DHCP) puis relance le script."
  CUR_PREFIX="${CUR_ADDR##*/}"
  [ "$CUR_PREFIX" = "24" ] || warn "préfixe /$CUR_PREFIX détecté : le kit suppose un /24"
  SERVER_IP="${SERVER_IP:-${CUR_ADDR%%/*}}"
  LAB_NET="${LAB_NET:-${SERVER_IP%.*}}"
else
  LAB_NET="${LAB_NET:-192.168.1}"
  SERVER_IP="${SERVER_IP:-${LAB_NET}.1}"
fi
DHCP_START="${LAB_NET}.100"
DHCP_END="${LAB_NET}.200"

# 192.168.1.1  ->  1.168.192.in-addr.arpa
IFS=. read -r o1 o2 o3 _ <<<"$SERVER_IP"
REV_SERVER_IP="${o3}.${o2}.${o1}.in-addr.arpa"
export LAB_IF SERVER_IP LAB_NET DHCP_START DHCP_END REV_SERVER_IP

info "Mode réseau          : $MODE"
info "Réseau du labo       : ${LAB_NET}.0/24"
info "Adresse du serveur   : $SERVER_IP  ($LAB_IF)"
if [ "$MODE" = "shared" ]; then
  info "Rôle                 : simple hôte du point d'accès (DHCP et Internet par le routeur)"
  info "DHCP du serveur      : désactivé (le routeur du point d'accès le fournit)"
  info "NAT                  : aucun (inutile sur un réseau partagé)"
else
  info "Rôle                 : passerelle + DHCP du labo"
  info "DHCP du serveur      : ${DHCP_START} → ${DHCP_END}"
  if [ "$ENABLE_NAT" = "1" ]; then
    info "NAT vers Internet    : ${LAB_NET}.0/24 → $UPLINK_IF"
  else
    info "NAT                  : désactivé (labo isolé)"
  fi
fi

# =============================================================================
# 1. Paquets
# =============================================================================
info "Installation des outils réseau"
export DEBIAN_FRONTEND=noninteractive
echo "wireshark-common wireshark-common/install-setuid boolean false" | debconf-set-selections

apt-get update -qq
apt-get install -y -qq \
  iproute2 net-tools traceroute mtr-tiny dnsutils nmap tcpdump tshark \
  iperf3 curl netcat-openbsd openssh-server nginx ssl-cert dnsmasq \
  ufw iptables nftables ethtool lsof gettext-base openssl ca-certificates python3 \
  >/dev/null
ok "iproute2, net-tools, traceroute, mtr, dig/nslookup, nmap, tcpdump/tshark, iperf3, nc, ssh, nginx, dnsmasq, ufw, iptables, nft"

# =============================================================================
# 2. Compte de démonstration (ssh / scp)
# =============================================================================
info "Compte de démonstration $TP_USER"
if id "$TP_USER" >/dev/null 2>&1; then
  ok "le compte $TP_USER existe déjà"
else
  useradd -m -s /bin/bash "$TP_USER"
  echo "$TP_USER:$TP_PASSWORD" | chpasswd
  ok "compte $TP_USER créé (mot de passe : $TP_PASSWORD — à changer après la démo)"
fi
systemctl enable --now ssh >/dev/null 2>&1 || systemctl enable --now sshd >/dev/null 2>&1 || true
ok "sshd actif sur le port 22"

# =============================================================================
# 3. DNS + DHCP (dnsmasq)
# =============================================================================
if [ "$ENABLE_DHCP" = "1" ]; then
  info "dnsmasq : DNS de la zone tp.local + DHCP du labo"
else
  info "dnsmasq : DNS de la zone tp.local (pas de DHCP)"
fi

# systemd-resolved occupe le port 53 : on le libère pour dnsmasq.
if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
  systemctl disable --now systemd-resolved >/dev/null 2>&1 || true
  rm -f /etc/resolv.conf
  printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf
  warn "systemd-resolved arrêté (port 53 libéré). DNS du serveur : 1.1.1.1 / 8.8.8.8"
fi
if ss -lunH 'sport = :53' 2>/dev/null | grep -q .; then
  warn "un service écoute déjà en UDP 53 (voir : sudo ss -lunp 'sport = :53')"
  warn "dnsmasq risque de ne pas démarrer : libère le port puis relance le script."
fi

# Le fichier principal doit inclure /etc/dnsmasq.d
if ! grep -qE '^[[:space:]]*conf-dir=/etc/dnsmasq\.d' /etc/dnsmasq.conf 2>/dev/null; then
  printf '\n# ajout TP INF3611\nconf-dir=/etc/dnsmasq.d/,*.conf\n' >>/etc/dnsmasq.conf
fi

envsubst '${LAB_IF} ${SERVER_IP} ${LAB_NET} ${DHCP_START} ${DHCP_END} ${REV_SERVER_IP}' \
  <"$CFG/dnsmasq.conf.tpl" >/etc/dnsmasq.d/tp-lab.conf
# mode partagé : pas de serveur DHCP concurrent de celui du point d'accès
if [ "$ENABLE_DHCP" = "0" ]; then
  sed -i '/# BEGIN-DHCP/,/# END-DHCP/d' /etc/dnsmasq.d/tp-lab.conf
fi
dnsmasq --test >/dev/null 2>&1 || die "configuration dnsmasq invalide : sudo dnsmasq --test"
systemctl enable dnsmasq >/dev/null 2>&1
systemctl restart dnsmasq || die "dnsmasq ne démarre pas : journalctl -u dnsmasq -n 30"
ok "DNS : serveur.tp.local, web.tp.local, dns.tp.local, lab.tp.local → $SERVER_IP"

# Le serveur doit joindre ses propres services par nom même si son résolveur
# système n'est pas dnsmasq (curl, ssh, scp). dig/nslookup, eux, interrogent
# dnsmasq explicitement : @127.0.0.1.
if ! grep -q 'TP-LAB-HOSTS-BEGIN' /etc/hosts; then
  {
    printf '\n# TP-LAB-HOSTS-BEGIN (install.sh)\n'
    printf '%s\tserveur.tp.local web.tp.local dns.tp.local\n' "$SERVER_IP"
    printf '# TP-LAB-HOSTS-END\n'
  } >>/etc/hosts
  ok "noms locaux ajoutés à /etc/hosts du serveur"
fi

# =============================================================================
# 4. Site web de test (HTTP 80 + HTTPS 443 auto-signé)
# =============================================================================
info "nginx : site de test HTTP/HTTPS"

mkdir -p "$WEB_ROOT"
if [ ! -f "$WEB_ROOT/fichier-20m.bin" ]; then
  dd if=/dev/zero of="$WEB_ROOT/fichier-20m.bin" bs=1M count=20 status=none
fi

cat >"$WEB_ROOT/index.html" <<HTML
<!doctype html>
<html lang="fr">
<head><meta charset="utf-8"><title>Serveur de TP — INF3611</title>
<style>body{font-family:system-ui,sans-serif;max-width:46rem;margin:3rem auto;padding:0 1rem;line-height:1.6}
code{background:#eee;padding:.1rem .3rem;border-radius:.2rem}table{border-collapse:collapse}td,th{border:1px solid #ccc;padding:.3rem .6rem;text-align:left}</style>
</head>
<body>
<h1>Serveur de TP — commandes avancées réseau</h1>
<p>Hôte : <code>web.tp.local</code> (${SERVER_IP}) — Groupe 12, INF3611.</p>
<table>
<tr><th>Service</th><th>Port</th><th>Commande de test</th></tr>
<tr><td>HTTP</td><td>80</td><td><code>curl -I http://web.tp.local</code></td></tr>
<tr><td>HTTPS (auto-signé)</td><td>443</td><td><code>curl -kI https://web.tp.local</code></td></tr>
<tr><td>SSH</td><td>22</td><td><code>nc -zv ${SERVER_IP} 22</code></td></tr>
<tr><td>iperf3</td><td>5201</td><td><code>iperf3 -c ${SERVER_IP} -t 10</code></td></tr>
<tr><td>DNS / DHCP</td><td>53 / 67</td><td><code>dig +short web.tp.local</code></td></tr>
</table>
<p>Fichier de test pour les transferts : <a href="fichier-20m.bin">fichier-20m.bin</a> (20 Mio).</p>
</body>
</html>
HTML

mkdir -p "$CERT_DIR"
if [ ! -f "$CERT_DIR/web.tp.local.crt" ]; then
  openssl req -x509 -nodes -newkey rsa:2048 -days 825 \
    -keyout "$CERT_DIR/web.tp.local.key" \
    -out "$CERT_DIR/web.tp.local.crt" \
    -subj "/C=CM/ST=Centre/L=Yaounde/O=TP INF3611 Groupe 12/CN=web.tp.local" \
    -addext "subjectAltName=DNS:web.tp.local,DNS:serveur.tp.local,IP:${SERVER_IP}" \
    >/dev/null 2>&1
  chmod 600 "$CERT_DIR/web.tp.local.key"
fi

install -m 644 "$CFG/nginx-tp-lab.conf" /etc/nginx/sites-available/tp-lab
ln -sf /etc/nginx/sites-available/tp-lab /etc/nginx/sites-enabled/tp-lab
# nginx n'autorise qu'un seul default_server : on retire le site par défaut.
rm -f /etc/nginx/sites-enabled/default
nginx -t >/dev/null 2>&1 || die "configuration nginx invalide : sudo nginx -t"
systemctl enable nginx >/dev/null 2>&1
systemctl restart nginx || die "nginx ne démarre pas : journalctl -u nginx -n 30"
ok "HTTP 80 et HTTPS 443 servis depuis $WEB_ROOT"

# =============================================================================
# 5. iperf3 en service (port 5201)
# =============================================================================
info "iperf3 en service (port 5201)"
install -m 644 "$CFG/iperf3.service" /etc/systemd/system/iperf3.service
systemctl daemon-reload
systemctl enable iperf3 >/dev/null 2>&1
systemctl restart iperf3 || die "iperf3 ne démarre pas : journalctl -u iperf3 -n 30"
ok "iperf3 -s en écoute sur 0.0.0.0:5201"

# =============================================================================
# 6. Routage et NAT vers Internet (optionnel)
# =============================================================================
if [ "$ENABLE_NAT" = "1" ] && [ -n "$UPLINK_IF" ]; then
  install -m 644 "$CFG/99-tp-lab-sysctl.conf" /etc/sysctl.d/99-tp-lab-sysctl.conf
  sysctl -q --system >/dev/null 2>&1 || true
  ok "net.ipv4.ip_forward=1 (persistant)"
fi

if [ "$ENABLE_NAT" = "1" ] && [ -n "$UPLINK_IF" ]; then
  info "NAT ${LAB_NET}.0/24 → $UPLINK_IF"

  # ufw refuse le transit par défaut : on l'autorise (serveur passerelle de labo).
  sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw || true

  if ! grep -q 'TP-LAB-NAT-BEGIN' /etc/ufw/before.rules 2>/dev/null; then
    {
      printf '# TP-LAB-NAT-BEGIN (généré par tp-lab/install.sh)\n'
      printf '*nat\n:POSTROUTING ACCEPT [0:0]\n'
      printf -- '-A POSTROUTING -s %s.0/24 -o %s -j MASQUERADE\n' "$LAB_NET" "$UPLINK_IF"
      printf 'COMMIT\n# TP-LAB-NAT-END\n'
      cat /etc/ufw/before.rules
    } >/tmp/tp-lab-before.rules
    install -m 640 -o root -g root /tmp/tp-lab-before.rules /etc/ufw/before.rules
    rm -f /tmp/tp-lab-before.rules
  fi
  ok "MASQUERADE ${LAB_NET}.0/24 → $UPLINK_IF (persistant via /etc/ufw/before.rules)"
else
  if [ "$MODE" = "shared" ]; then
    ok "pas de NAT : chaque PC garde son accès Internet par le point d'accès"
  else
    warn "pas de NAT : les PC du labo n'auront accès qu'aux services du serveur"
    warn "(ping 8.8.8.8, traceroute example.com et dig externe échoueront volontairement)"
  fi
fi

# =============================================================================
# 7. Pare-feu du serveur (ufw)
# =============================================================================
if [ "$ENABLE_UFW" = "1" ]; then
  info "ufw : accès autorisé depuis le réseau du labo"
  ufw allow from "${LAB_NET}.0/24" comment 'TP INF3611 - labo' >/dev/null
  ufw allow 22/tcp   comment 'SSH'  >/dev/null
  ufw allow 80/tcp   comment 'HTTP' >/dev/null
  ufw allow 443/tcp  comment 'HTTPS' >/dev/null
  ufw allow 5201/tcp comment 'iperf3' >/dev/null
  ufw allow 53/tcp >/dev/null; ufw allow 53/udp comment 'DNS' >/dev/null
  ufw allow 67/udp >/dev/null; ufw allow 68/udp comment 'DHCP' >/dev/null
  if [ -n "$UPLINK_IF" ] && [ "$ENABLE_NAT" = "1" ]; then
    ufw route allow in on "$LAB_IF" out on "$UPLINK_IF" >/dev/null
  fi
  ufw --force enable >/dev/null
  ok "ufw actif (22, 53, 67/68, 80, 443, 5201 + tout depuis ${LAB_NET}.0/24)"
  ufw reload >/dev/null 2>&1 || true
else
  warn "ufw laissé tel quel (ENABLE_UFW=0)"
fi

# =============================================================================
# 8. Adresse IP du serveur
# =============================================================================
if [ "$MODE" = "shared" ]; then
  ok "$LAB_IF porte $SERVER_IP (adresse attribuée par le point d'accès)"
  if ! ip -4 -br addr show dev "$LAB_IF" | grep -q " ${SERVER_IP}/"; then
    warn "l'adresse $SERVER_IP n'est plus celle de $LAB_IF : mets-la à jour dans tes notes"
  fi
elif ! ip -4 -br addr show dev "$LAB_IF" | grep -q " ${SERVER_IP}/24"; then
  warn "L'interface $LAB_IF ne porte pas encore $SERVER_IP/24 :"
  warn "les PC du labo ne verront pas le serveur et le DHCP ne répondra pas."
  warn "Configure-la avec :  sudo LAB_IF=$LAB_IF LAB_NET=$LAB_NET $HERE/scripts/set-ip.sh"
  warn "(ou avec Netplan : modèle dans $CFG/40-tp-lab-netplan.yaml.tpl)"
else
  ok "$LAB_IF porte $SERVER_IP/24"
fi

# =============================================================================
# 9. Récapitulatif
# =============================================================================
cat <<EOF

=======================================================================
 SERVEUR DE TP PRÊT   (mode : $MODE)
=======================================================================
 Réseau du labo        : ${LAB_NET}.0/24
 Adresse du serveur    : $SERVER_IP  ($LAB_IF)
 Rôle réseau           : $( [ "$MODE" = shared ] && echo "hôte du point d'accès — DHCP et Internet fournis par son routeur" || echo "passerelle + DHCP du labo" )
 DNS du labo           : $SERVER_IP  (zone tp.local)
 DHCP                  : $( [ "$ENABLE_DHCP" = "1" ] && echo "${DHCP_START} → ${DHCP_END} (dnsmasq)" || echo "routeur du point d'accès" )
 Internet des PC       : $( [ "$ENABLE_NAT" = "1" ] && echo "NAT via $UPLINK_IF" || echo "point d'accès" )

 Services à tester depuis les PC
   HTTP        http://${SERVER_IP}/            (http://web.tp.local si le DNS est le serveur)
   HTTPS       https://${SERVER_IP}/           (certificat auto-signé → curl -k)
   SSH/SCP     ssh ${TP_USER}@${SERVER_IP}
   iperf3      iperf3 -c ${SERVER_IP} -t 10
   DNS         dig +short web.tp.local @${SERVER_IP}
   nmap        nmap -sn ${LAB_NET}.0/24

 Vérifier toutes les commandes du rapport :
   sudo $HERE/tests/run-all-tests.sh

 Labo jetable (routage, MTU, pare-feu) sans machine virtuelle :
   sudo $HERE/lab/lab.sh up

 Sur chaque PC, connecté au MÊME point d'accès :
   sudo SERVER_IP=${SERVER_IP} $HERE/scripts/setup-client.sh

 Retour arrière : sudo $HERE/uninstall.sh
=======================================================================
EOF
