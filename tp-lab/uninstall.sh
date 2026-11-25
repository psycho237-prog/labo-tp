#!/usr/bin/env bash
# =============================================================================
#  TP INF3611 — retour arrière : retire tout ce que install.sh a mis en place
#  (les paquets installés restent ; le compte de démonstration aussi)
#
#  Usage : sudo ./uninstall.sh
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_NET="${LAB_NET:-192.168.1}"
[ "$(id -u)" -eq 0 ] || { echo "Lance avec sudo." >&2; exit 1; }

echo "== iperf3 =="
systemctl disable --now iperf3 2>/dev/null && echo "  service arrêté"
rm -f /etc/systemd/system/iperf3.service
systemctl daemon-reload

echo "== dnsmasq =="
rm -f /etc/dnsmasq.d/tp-lab.conf
systemctl restart dnsmasq 2>/dev/null && echo "  configuration du labo retirée"

echo "== nginx =="
rm -f /etc/nginx/sites-enabled/tp-lab /etc/nginx/sites-available/tp-lab
[ -f /etc/nginx/sites-available/default ] && ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
systemctl restart nginx 2>/dev/null || true

echo "== NAT (ufw) =="
if grep -q 'TP-LAB-NAT-BEGIN' /etc/ufw/before.rules 2>/dev/null; then
  sed -i '/# TP-LAB-NAT-BEGIN/,/# TP-LAB-NAT-END/d' /etc/ufw/before.rules
  sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="DROP"/' /etc/default/ufw
  echo "  bloc NAT retiré"
fi

echo "== ufw : règles du labo =="
for i in 1 2 3; do
  ufw --force delete allow from "${LAB_NET}.0/24" >/dev/null 2>&1 || break
done
for rule in 22/tcp 80/tcp 443/tcp 5201/tcp 53/tcp 53/udp 67/udp 68/udp; do
  ufw --force delete allow "$rule" >/dev/null 2>&1 || true
done
ufw reload >/dev/null 2>&1 || true
echo "  règles supprimées"

echo "== /etc/hosts =="
if grep -q 'TP-LAB-HOSTS-BEGIN' /etc/hosts; then
  sed -i '/# TP-LAB-HOSTS-BEGIN/,/# TP-LAB-HOSTS-END/d' /etc/hosts
  echo "  noms locaux retirés"
fi

echo "== fichiers =="
rm -rf /var/www/tp-lab /etc/ssl/tp-lab /etc/sysctl.d/99-tp-lab-sysctl.conf
echo "  /var/www/tp-lab, /etc/ssl/tp-lab, sysctl du labo"

echo "== labo namespaces =="
"$HERE/lab/lab.sh" down 2>/dev/null || true

cat <<'EOF'

Terminé. Points laissés en place volontairement :
  - les paquets installés (nmap, tcpdump, iperf3, dnsutils…)
  - le compte de démonstration « tp »
  - systemd-resolved, s'il a été arrêté : sudo systemctl enable --now systemd-resolved
    puis sudo ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
  - l'adresse IP fixe posée avec scripts/set-ip.sh (à remettre en DHCP si besoin)
EOF
