#!/usr/bin/env bash
# =============================================================================
#  TP INF3611 — laboratoire réseau jetable (network namespaces)
#  Aucune machine virtuelle, aucun matériel supplémentaire : tout tient
#  dans le noyau du serveur et disparaît avec « lab.sh down ».
#
#      h1                         r1                         h2
#   10.20.0.10  ───────────  10.20.0.1  |  10.20.1.1  ───────────  10.20.1.5
#   (poste)                    routeur Linux                    (serveur de test)
#                                  MTU 1400 côté h2
#
#  Ce montage sert à démontrer :
#    - traceroute avec un vrai saut intermédiaire          (§3.2)
#    - nmap / nc / curl sur un second sous-réseau          (§8, §9)
#    - ping -M do -s 1472 qui échoue, -s 1372 qui passe    (cas 2, MTU)
#    - iptables FORWARD qui bloque un port                 (cas 3, §10.2)
#    - correction MSS (--clamp-mss-to-pmtu)                (cas 2)
#
#  Usage :
#     sudo ./lab.sh up
#     sudo ./lab.sh status
#     sudo ./lab.sh firewall on|off
#     sudo ./lab.sh mtu-fix on|off
#     sudo ./lab.sh down
# =============================================================================
set -euo pipefail

A="${A:-10.20.0}"          # sous-réseau 1 (poste h1)
B="${B:-10.20.1}"          # sous-réseau 2 (serveur h2) — cas 2 du rapport
MTU="${MTU:-1400}"         # MTU réduit côté h2 (simule un tunnel)
WWW_ROOT="${WWW_ROOT:-/var/www/tp-lab}"
STATE_DIR="${STATE_DIR:-/run/tp-lab}"

A_H1="${A}.10"
A_R1="${A}.1"
B_R1="${B}.1"
B_H2="${B}.5"

info() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[1;32m[ok]\033[0m %s\n' "$*"; }
warn() { printf '    \033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mERREUR :\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || exec sudo -E bash "$0" "$@"
command -v ip >/dev/null || die "iproute2 manquant."
command -v iptables >/dev/null || die "iptables manquant (sudo apt install iptables)."

# -----------------------------------------------------------------------------
# Arrêt / nettoyage
# -----------------------------------------------------------------------------
stop_listeners() {
  if [ -f "$STATE_DIR/http-ns.pid" ]; then
    kill "$(cat "$STATE_DIR/http-ns.pid")" 2>/dev/null || true
    rm -f "$STATE_DIR/http-ns.pid"
  fi
  ip netns exec h2 pkill -f 'http\.server 8080' 2>/dev/null || true
  ip netns exec h2 pkill -f 'iperf3 -s' 2>/dev/null || true
}

down() {
  stop_listeners
  local ns
  for ns in h1 r1 h2; do
    if ip netns list 2>/dev/null | awk '{print $1}' | grep -qx "$ns"; then
      ip netns del "$ns" 2>/dev/null || true
      ok "namespace $ns supprimé"
    fi
  done
  rmdir "$STATE_DIR" 2>/dev/null || true
  ok "labo arrêté"
}

# -----------------------------------------------------------------------------
# Mise en place
# -----------------------------------------------------------------------------
up() {
  if ip netns list 2>/dev/null | awk '{print $1}' | grep -qx h1; then
    down
  fi

  info "Création de h1, r1, h2"
  ip netns add h1
  ip netns add r1
  ip netns add h2

  # câbles virtuels (veth) : un bout dans chaque namespace
  ip link add veth-h1 netns h1 type veth peer name veth-r1a netns r1
  ip link add veth-h2 netns h2 type veth peer name veth-r1b netns r1

  info "Configuration des adresses"
  ip -n h1 link set lo up
  ip -n h1 addr add "${A_H1}/24" dev veth-h1
  ip -n h1 link set veth-h1 up
  ip -n h1 route add default via "$A_R1"

  ip -n r1 link set lo up
  ip -n r1 addr add "${A_R1}/24" dev veth-r1a
  ip -n r1 addr add "${B_R1}/24" dev veth-r1b
  ip -n r1 link set veth-r1a up
  # MTU réduit des deux côtés du lien vers h2 : le chemin fait 1400 octets
  ip -n r1 link set veth-r1b mtu "$MTU" up
  ip netns exec r1 sysctl -qw net.ipv4.ip_forward=1

  ip -n h2 link set lo up
  ip -n h2 addr add "${B_H2}/24" dev veth-h2
  ip -n h2 link set veth-h2 mtu "$MTU" up
  ip -n h2 route add default via "$B_R1"

  ok "h1 ${A_H1}/24 → passerelle ${A_R1}"
  ok "r1 ${A_R1}/24 + ${B_R1}/24 (ip_forward=1, MTU ${MTU} côté h2)"
  ok "h2 ${B_H2}/24 (MTU ${MTU})"

  info "Démarrage des services de h2 (cibles de test)"
  mkdir -p "$STATE_DIR"
  if [ -d "$WWW_ROOT" ]; then
    ip netns exec h2 python3 -m http.server 8080 --directory "$WWW_ROOT" \
      >/dev/null 2>&1 &
    echo $! >"$STATE_DIR/http-ns.pid"
    ok "HTTP 8080 dans h2 (racine $WWW_ROOT)"
  else
    warn "$WWW_ROOT absent : lance install.sh pour avoir un serveur HTTP de test"
  fi
  if command -v iperf3 >/dev/null; then
    ip netns exec h2 iperf3 -s -p 5201 -D
    ok "iperf3 5201 dans h2"
  else
    warn "iperf3 absent : sudo apt install iperf3"
  fi

  echo
  echo "  Démonstrations :"
  echo "    sudo ip netns exec h1 ping -c 3 ${B_H2}"
  echo "    sudo ip netns exec h1 traceroute -n ${B_H2}          # 2 sauts : r1 puis h2"
  echo "    sudo ip netns exec h1 curl -s http://${B_H2}:8080/ | head"
  echo "    sudo ip netns exec h1 nc -zv ${B_H2} 8080"
  echo "    sudo ip netns exec h1 nmap -Pn -p 8080,5201 ${B_H2}"
  echo "    sudo ip netns exec h1 ping -M do -s 1472 -c 2 ${B_H2}   # échoue (MTU ${MTU})"
  echo "    sudo ip netns exec h1 ping -M do -s $((MTU - 28)) -c 2 ${B_H2}   # passe"
  echo "    sudo ip netns exec h1 iperf3 -c ${B_H2} -t 5"
  echo
  echo "  Puis : sudo $0 firewall on      (bloque 8080 via iptables FORWARD)"
  echo "         sudo $0 mtu-fix on       (clamp MSS : corrige le cas 2)"
  echo "         sudo $0 down"
}

status() {
  [ "$(ip netns list 2>/dev/null | wc -l)" -ge 3 ] || die "labo absent : sudo $0 up"
  local ns
  for ns in h1 r1 h2; do
    printf '\n\033[1m--- %s ---\033[0m\n' "$ns"
    ip -n "$ns" -br addr
    ip -n "$ns" route
  done
  printf '\n\033[1m--- pare-feu r1 ---\033[0m\n'
  ip netns exec r1 iptables -S 2>/dev/null || true
  ip netns exec r1 iptables -t mangle -S 2>/dev/null || true
  printf '\n\033[1m--- services h2 ---\033[0m\n'
  ip netns exec h2 ss -tlnp 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# Pare-feu : cas 3 du rapport (blocage d'un flux routé)
# -----------------------------------------------------------------------------
firewall() {
  local action="${1:-}"
  [ "$(ip netns list 2>/dev/null | awk '{print $1}' | grep -cx r1)" -eq 1 ] \
    || die "labo absent : sudo $0 up"
  case "$action" in
    on)
      if ip netns exec r1 iptables -C FORWARD -i veth-r1a -d "$B_H2" -p tcp --dport 8080 -j DROP 2>/dev/null; then
        ok "règle déjà présente"
      else
        ip netns exec r1 iptables -A FORWARD -i veth-r1a -d "$B_H2" -p tcp --dport 8080 -j DROP
        ok "r1 : DROP tcp/8080 venant du sous-réseau ${A}.0/24"
      fi
      ip netns exec r1 iptables -S FORWARD
      ;;
    off)
      local n=0
      while ip netns exec r1 iptables -D FORWARD -i veth-r1a -d "$B_H2" -p tcp --dport 8080 -j DROP 2>/dev/null; do
        n=$((n + 1))
      done
      ok "$n règle(s) supprimée(s)"
      ip netns exec r1 iptables -S FORWARD
      ;;
    *) die "usage : $0 firewall on|off" ;;
  esac
}

# -----------------------------------------------------------------------------
# Cas 2 du rapport : MSS trop grand pour le MTU du chemin
# -----------------------------------------------------------------------------
mtu_fix() {
  local action="${1:-}"
  [ "$(ip netns list 2>/dev/null | awk '{print $1}' | grep -cx r1)" -eq 1 ] \
    || die "labo absent : sudo $0 up"
  case "$action" in
    on)
      if ip netns exec r1 iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; then
        ok "règle MSS déjà présente"
      else
        ip netns exec r1 iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
        ok "r1 : MSS aligné sur le MTU du chemin"
      fi
      ip netns exec r1 iptables -t mangle -S FORWARD
      ;;
    off)
      local n=0
      while ip netns exec r1 iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; do
        n=$((n + 1))
      done
      ok "$n règle(s) MSS supprimée(s)"
      ip netns exec r1 iptables -t mangle -S FORWARD
      ;;
    *) die "usage : $0 mtu-fix on|off" ;;
  esac
}

case "${1:-}" in
  up)       up ;;
  down)     down ;;
  status)   status ;;
  firewall) shift; firewall "${1:-}" ;;
  mtu-fix)  shift; mtu_fix "${1:-}" ;;
  *) cat <<USAGE
Usage : sudo $0 {up|down|status|firewall on|firewall off|mtu-fix on|mtu-fix off}

  up        crée h1 (${A}.10) — r1 (routeur) — h2 (${B}.5, MTU ${MTU})
  status    adresses, routes, pare-feu et ports des trois namespaces
  firewall  bloque/débloque le port 8080 de h2 depuis h1 (cas 3)
  mtu-fix   ajoute/retire le clamp MSS sur r1 (cas 2)
  down      supprime tout (namespaces, processus, règles)
USAGE
            exit 1 ;;
esac
