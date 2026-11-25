#!/usr/bin/env bash
# =============================================================================
#  TP INF3611 — fixe l'adresse IP du serveur sur l'interface du labo
#
#  Usage : sudo LAB_IF=eth0 ./set-ip.sh
#          sudo LAB_IF=enp3s0 LAB_NET=192.168.1 ./set-ip.sh
#
#  Sur un poste avec NetworkManager (bureau), la configuration est enregistrée
#  dans le profil de connexion : elle survit au redémarrage.
#  Sans NetworkManager, l'adresse est posée avec ip (temporaire).
# =============================================================================
set -euo pipefail

LAB_NET="${LAB_NET:-192.168.1}"
SERVER_IP="${LAB_NET}.1"
LAB_IF="${LAB_IF:-}"

[ "$(id -u)" -eq 0 ] || { echo "Lance avec sudo." >&2; exit 1; }
if [ -z "$LAB_IF" ]; then
  echo "Indique l'interface filaire, par exemple : sudo LAB_IF=eth0 $0" >&2
  ip -br link
  exit 1
fi
ip link show "$LAB_IF" >/dev/null 2>&1 || { echo "Interface $LAB_IF inconnue." >&2; exit 1; }

# Refus sur une interface Wi-Fi : on casserait la connexion Internet du serveur.
if command -v nmcli >/dev/null 2>&1; then
  TYPE="$(nmcli -t -f DEVICE,TYPE device status | awk -F: -v d="$LAB_IF" '$1==d {print $2; exit}')"
  if [ "$TYPE" = "wifi" ]; then
    echo "$LAB_IF est une interface Wi-Fi : choisis la carte filaire." >&2
    exit 1
  fi
fi

echo "Interface $LAB_IF → ${SERVER_IP}/24"
printf 'Cette opération change la configuration IP de %s. Continuer ? [o/N] ' "$LAB_IF"
read -r answer
case "$answer" in
  o|O|oui|y|Y) ;;
  *) echo "Annulé."; exit 0 ;;
esac

CON=""
if command -v nmcli >/dev/null 2>&1; then
  CON="$(nmcli -t -f NAME,DEVICE connection show --active | awk -F: -v d="$LAB_IF" '$2==d {print $1; exit}')"
fi

if [ -n "$CON" ]; then
  nmcli connection modify "$CON" ipv4.addresses "${SERVER_IP}/24" ipv4.method manual
  nmcli connection up "$CON" >/dev/null
  echo "Profil NetworkManager « $CON » configuré (persistant)."
else
  ip addr replace "${SERVER_IP}/24" dev "$LAB_IF"
  ip link set "$LAB_IF" up
  echo "Adresse posée avec ip (temporaire : perdue au redémarrage)."
  echo "Pour la rendre persistante : Netplan (config/40-tp-lab-netplan.yaml.tpl)"
  echo "ou NetworkManager (nmcli)."
fi

ip -4 -br addr show dev "$LAB_IF"
