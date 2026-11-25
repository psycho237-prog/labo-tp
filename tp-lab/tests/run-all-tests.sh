#!/usr/bin/env bash
# =============================================================================
#  TP INF3611 — vérification complète du laboratoire
#
#  Rejoue, dans l'ordre du rapport, toutes les commandes Linux :
#  couches 1-2, adressage, chemin, DNS, ports, capture, nmap, HTTP,
#  débit, SSH, pare-feu — puis le labo namespaces (routage, MTU, blocage).
#
#  Chaque commande est journalisée dans tests/journal/<horodatage>/
#  et le script affiche un tableau récapitulatif OK / ÉCHEC.
#
#  Usage : sudo ./run-all-tests.sh
#          sudo LAB_NET=192.168.1 LAB_IF=eth0 ./run-all-tests.sh
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TPLAB="$(dirname "$HERE")"

LAB_NET="${LAB_NET:-192.168.1}"
SERVER_IP="${LAB_NET}.1"
LAB_IF="${LAB_IF:-$(ip route show default 2>/dev/null | awk '/^default/ {print $5; exit}')}"
TP_USER="${TP_USER:-tp}"
JOURNAL="${JOURNAL:-$HERE/journal}"

# Toutes les commandes de diagnostic demandent root (ss -p, tcpdump, nmap -sS…)
if [ "$(id -u)" -ne 0 ]; then
  echo "Relance avec sudo…"
  exec sudo -E bash "$0" "$@"
fi

OUT="$JOURNAL/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"

PASS=0
FAIL=0
N=0
RESULTS=()

blue()  { printf '\n\033[1;34m%s\033[0m\n' "$*"; }
cyan()  { printf '\n\033[1;36m%s\033[0m\n' "$*"; }
red()   { printf '\033[1;31m%s\033[0m\n' "$*"; }
green() { printf '\033[1;32m%s\033[0m\n' "$*"; }

have() { command -v "$1" >/dev/null 2>&1; }

_slug() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]\+/-/g' | cut -c1-55; }
# renseigne $FILE (pas de sous-shell : le compteur N doit survivre)
_next_file() {
  N=$((N + 1))
  FILE="$OUT/$(printf '%02d' "$N")-$(_slug "$1").log"
}

_expect() { # _expect <ok|fail> <titre> <fichier> <rc>
  local want="$1" title="$2" file="$3" rc="$4"
  local verdict
  if { [ "$want" = ok ] && [ "$rc" -eq 0 ]; } || { [ "$want" = fail ] && [ "$rc" -ne 0 ]; }; then
    verdict="OK"
    PASS=$((PASS + 1))
    printf '  \033[1;32m→ OK\033[0m  (%s)\n' "${file##*/}"
  else
    verdict="ECHEC"
    FAIL=$((FAIL + 1))
    printf '  \033[1;31m→ ÉCHEC\033[0m (rc=%s)  %s\n' "$rc" "${file##*/}"
  fi
  RESULTS+=("$verdict|$title|${file##*/}")
  sed -n '1,25p' "$file" | sed 's/^/    /'
}

run() { # run <titre> <commande> [args...]
  local title="$1"
  shift
  _next_file "$title"
  local file="$FILE"
  cyan "### $title"
  printf '$ %s\n' "$*"
  if "$@" >"$file" 2>&1; then
    _expect ok "$title" "$file" 0
  else
    _expect ok "$title" "$file" $?
  fi
}

run_sh() { # run_sh <titre> <ligne de commande shell>
  local title="$1"
  shift
  _next_file "$title"
  local file="$FILE"
  cyan "### $title"
  printf '$ %s\n' "$*"
  if bash -c "$*" >"$file" 2>&1; then
    _expect ok "$title" "$file" 0
  else
    _expect ok "$title" "$file" $?
  fi
}

# Commande dont l'échec est le comportement attendu (ex : MTU trop grand)
run_expect_fail() {
  local title="$1"
  shift
  _next_file "$title"
  local file="$FILE"
  cyan "### $title  (échec attendu)"
  printf '$ %s\n' "$*"
  if "$@" >"$file" 2>&1; then
    _expect fail "$title" "$file" 0
  else
    _expect fail "$title" "$file" $?
  fi
}

# -----------------------------------------------------------------------------
blue "TP INF3611 — vérification du laboratoire"
echo "Serveur : $SERVER_IP   interface : $LAB_IF   journal : $OUT"

# =============================================================================
blue "1. Couche physique et liaison  (ip link, ethtool, ip neigh)"
# =============================================================================
run "ip -br link" ip -br link
[ -n "$LAB_IF" ] && run "ethtool $LAB_IF" ethtool "$LAB_IF"
[ -n "$LAB_IF" ] && run "ethtool -S $LAB_IF" ethtool -S "$LAB_IF"
run "ip neigh (cache ARP)" ip neigh

# =============================================================================
blue "2. Réseau : adresse et route  (ip addr, ip route)"
# =============================================================================
run "ip -br addr" ip -br addr
run "ip -br addr show dev $LAB_IF" ip -br addr show dev "$LAB_IF"
run "ip route" ip route
run "ip route get 8.8.8.8" ip route get 8.8.8.8
run "ping -c 4 127.0.0.1" ping -c 4 127.0.0.1
run "ping -c 4 $SERVER_IP" ping -c 4 "$SERVER_IP"
run "ping -c 4 8.8.8.8 (sortie Internet)" ping -c 4 8.8.8.8

# =============================================================================
blue "3. Diagnostic du chemin  (ping MTU, traceroute, mtr)"
# =============================================================================
run "ping -M do -s 1472 8.8.8.8 (test MTU 1500)" ping -c 2 -M do -s 1472 8.8.8.8
run "traceroute -n 8.8.8.8" traceroute -n -w 2 -q 1 8.8.8.8
run "traceroute -I -n 8.8.8.8 (sondes ICMP)" traceroute -I -n -w 2 -q 1 8.8.8.8
run "mtr -rwc 5 8.8.8.8" mtr -rwc 5 8.8.8.8

# =============================================================================
blue "4. Résolution DNS  (dig, nslookup)"
# =============================================================================
run "dig +short web.tp.local @127.0.0.1 (DNS du labo)" dig +short web.tp.local @127.0.0.1
run "dig +short serveur.tp.local @127.0.0.1" dig +short serveur.tp.local @127.0.0.1
run "dig -x $SERVER_IP @127.0.0.1 (PTR)" dig -x "$SERVER_IP" +short @127.0.0.1
run "dig +short MX gmail.com" dig +short MX gmail.com
run "dig @1.1.1.1 example.com (résolveur précis)" dig @1.1.1.1 example.com +short
run "nslookup google.com 1.1.1.1" nslookup google.com 1.1.1.1
run_sh "dig +trace example.com (délégation, coupé à 30 lignes)" "timeout 25 dig +trace example.com | head -30"

# =============================================================================
blue "5. Ports, sockets et processus  (ss, lsof)"
# =============================================================================
run "ss -tulpn (écoute)" ss -tulpn
run "ss -s (statistiques)" ss -s
run_sh "ss -tn state established '( dport = :443 )'" "ss -tn state established '( dport = :443 )'"
run "lsof -i :80 (qui sert le port 80)" lsof -i :80
run "lsof -i :5201 (iperf3)" lsof -i :5201

# =============================================================================
blue "6. Capture de paquets  (tcpdump, tshark)"
# =============================================================================
run_sh "tcpdump -i any -nn -c 5 'port 53' (5 paquets DNS)" \
  "( sleep 2; dig +short example.com >/dev/null; dig +short google.com >/dev/null; ) & timeout 20 tcpdump -i any -nn -c 5 'port 53'"
run_sh "tcpdump -i any icmp pendant un ping (capture .pcap)" \
  "( sleep 1; ping -c 5 127.0.0.1 >/dev/null; ) & timeout 20 tcpdump -i any -nn -c 10 -w '$OUT/capture-icmp.pcap' icmp"
run "tshark -r capture-icmp.pcap -Y icmp" tshark -r "$OUT/capture-icmp.pcap" -Y icmp -c 6

# =============================================================================
blue "7. Exploration du réseau  (nmap)"
# =============================================================================
run "nmap -sn ${LAB_NET}.0/24 (hôtes actifs)" nmap -sn "${LAB_NET}.0/24"
run "nmap -sT -Pn -p 22,80,443,5201 $SERVER_IP" nmap -sT -Pn -p 22,80,443,5201 "$SERVER_IP"
run "nmap -sV -p 80,443 $SERVER_IP (versions)" nmap -sV -p 80,443 "$SERVER_IP"
run "nmap -sS -p 1-1000 $SERVER_IP (scan SYN, root)" nmap -sS -p 1-1000 "$SERVER_IP"

# =============================================================================
blue "8. Tests applicatifs et débit  (curl, nc, iperf3)"
# =============================================================================
run "curl -I http://web.tp.local" curl -I http://web.tp.local
run "curl -kI https://web.tp.local (TLS auto-signé)" curl -kI https://web.tp.local
run_sh "curl -v https://web.tp.local (détail TLS, extrait)" "curl -skv https://web.tp.local -o /dev/null 2>&1 | head -25"
run_sh "curl code + temps total" \
  "curl -sS -k -o /dev/null -w 'Code=%{http_code} Temps=%{time_total}s\\n' https://web.tp.local"
run "nc -zv $SERVER_IP 443 (port ouvert)" nc -zv -w 3 "$SERVER_IP" 443
run_expect_fail "nc -zv $SERVER_IP 9999 (port fermé)" nc -zv -w 3 "$SERVER_IP" 9999
run "iperf3 -c 127.0.0.1 -t 3 (débit local)" iperf3 -c 127.0.0.1 -t 3
run_sh "openssl s_client (certificat présenté)" \
  "timeout 10 openssl s_client -connect 127.0.0.1:443 -servername web.tp.local </dev/null 2>/dev/null | openssl x509 -noout -subject -dates"

# =============================================================================
blue "9. Accès distant  (ssh, scp)"
# =============================================================================
run "ssh -V" ssh -V
run "nc -zv $SERVER_IP 22 (SSH en écoute)" nc -zv -w 3 "$SERVER_IP" 22
run_sh "bannière SSH du serveur" "nc -w 3 127.0.0.1 22 | head -1"

# =============================================================================
blue "10. Pare-feu du serveur  (ufw, iptables, nft)"
# =============================================================================
run "ufw status verbose" ufw status verbose
run "iptables -L -n -v --line-numbers" iptables -L -n -v --line-numbers
run_sh "nft list ruleset (extrait)" "nft list ruleset | head -40"
run "sysctl net.ipv4.ip_forward" sysctl net.ipv4.ip_forward

# =============================================================================
blue "11. Laboratoire namespaces  (routage, MTU, blocage)"
# =============================================================================
if ip netns list 2>/dev/null | awk '{print $1}' | grep -qx h1; then
  run "h1 → ping h2 (routé par r1)" ip netns exec h1 ping -c 3 10.20.1.5
  run "h1 → traceroute 10.20.1.5 (2 sauts)" ip netns exec h1 traceroute -n -w 2 10.20.1.5
  run "h1 → nc -zv 10.20.1.5 8080" ip netns exec h1 nc -zv -w 3 10.20.1.5 8080
  run_sh "h1 → curl http://10.20.1.5:8080/" "ip netns exec h1 curl -s http://10.20.1.5:8080/ | head -5"
  run "h1 → nmap -Pn -p 8080,5201 10.20.1.5" ip netns exec h1 nmap -Pn -p 8080,5201 10.20.1.5
  run "h1 → iperf3 -c 10.20.1.5 -t 3" ip netns exec h1 iperf3 -c 10.20.1.5 -t 3
  run_expect_fail "h1 → ping -M do -s 1472 10.20.1.5 (MTU 1400)" \
    ip netns exec h1 ping -c 2 -M do -s 1472 10.20.1.5
  run "h1 → ping -M do -s 1372 10.20.1.5 (passe)" \
    ip netns exec h1 ping -c 2 -M do -s 1372 10.20.1.5
  run "r1 → iptables -S FORWARD" ip netns exec r1 iptables -S FORWARD
else
  echo "  (labo absent — lancer : sudo $TPLAB/lab/lab.sh up)"
  RESULTS+=("IGNORE|labo namespaces|non lancé")
fi

# =============================================================================
blue "12. Commandes à lancer depuis chaque PC du labo"
# =============================================================================
cat >"$OUT/commandes-depuis-un-PC-client.txt" <<EOF
# À exécuter sur un PC client Linux du même réseau local
ip -br addr                      # doit montrer ${LAB_NET}.100-${LAB_NET}.200
ip route                         # default via ${SERVER_IP}
ping -c 4 ${SERVER_IP}
ping -c 4 8.8.8.8                # si le NAT est actif
dig +short web.tp.local
curl -kI https://web.tp.local
nc -zv ${SERVER_IP} 443
nmap -sn ${LAB_NET}.0/24
traceroute -n 8.8.8.8
iperf3 -c ${SERVER_IP} -t 10
ssh ${TP_USER}@${SERVER_IP}
scp ${TP_USER}@${SERVER_IP}:/var/www/tp-lab/fichier-20m.bin .
ssh -L 8080:localhost:80 ${TP_USER}@${SERVER_IP}   # puis http://localhost:8080
EOF
echo "  → $OUT/commandes-depuis-un-PC-client.txt"

# =============================================================================
# Récapitulatif
# =============================================================================
{
  echo "Journal : $OUT"
  echo
  printf '%-7s %s\n' "RÉSULTAT" "COMMANDE"
  printf '%-7s %s\n' "-------" "--------"
  for line in "${RESULTS[@]}"; do
    IFS='|' read -r verdict title file <<<"$line"
    printf '%-7s %s\n' "$verdict" "$title"
  done
  echo
  echo "OK : $PASS   ÉCHEC : $FAIL"
} >"$OUT/summary.txt"

blue "Récapitulatif"
printf '%-7s %s\n' "RÉSULTAT" "COMMANDE"
for line in "${RESULTS[@]}"; do
  IFS='|' read -r verdict title file <<<"$line"
  case "$verdict" in
    OK)     printf '\033[1;32m%-7s\033[0m %s\n' "$verdict" "$title" ;;
    ECHEC)  printf '\033[1;31m%-7s\033[0m %s\n' "$verdict" "$title" ;;
    *)      printf '%-7s %s\n' "$verdict" "$title" ;;
  esac
done

echo
printf 'OK : %s   ÉCHEC : %s   Journal : %s\n' "$PASS" "$FAIL" "$OUT"
echo "Détail complet : $OUT/summary.txt"
[ "$FAIL" -eq 0 ] && green "Toutes les commandes du rapport passent." \
  || red "Certaines commandes ont échoué : lire les .log du journal (et la section Dépannage du README)."
