# =============================================================================
#  TP INF3611 — dnsmasq : DNS de la zone tp.local + DHCP du laboratoire
#  Rendu par install.sh dans /etc/dnsmasq.d/tp-lab.conf
#  Ne pas éditer la copie dans /etc : modifier ce modèle puis relancer install.sh
# =============================================================================

# --- Portée : uniquement l'interface du labo ---------------------------------
interface=${LAB_IF}
bind-dynamic
# ne pas servir les requêtes venues d'ailleurs (VPN, Internet)
domain-needed
bogus-priv

# --- Domaine local ------------------------------------------------------------
domain=tp.local
expand-hosts
local=/tp.local/

# --- Enregistrements fixes, pour dig / nslookup ------------------------------
address=/serveur.tp.local/${SERVER_IP}
address=/web.tp.local/${SERVER_IP}
address=/dns.tp.local/${SERVER_IP}
# hôte fictif : montre qu'un nom peut résoudre vers une machine absente
address=/lab.tp.local/${LAB_NET}.50
# résolution inverse (dig -x ${SERVER_IP})
ptr-record=${REV_SERVER_IP},serveur.tp.local

# --- Résolveur amont : accès Internet du labo --------------------------------
# Labo isolé sans Internet : commenter ces trois lignes.
no-resolv
server=1.1.1.1
server=8.8.8.8
cache-size=1000

# --- DHCP ---------------------------------------------------------------------
# BEGIN-DHCP : bloqué supprimé automatiquement en mode « réseau partagé »
# (le routeur du point d'accès fournit alors les adresses)
dhcp-range=${DHCP_START},${DHCP_END},255.255.255.0,12h
# passerelle annoncée aux PC = le serveur (qui fait le NAT)
dhcp-option=3,${SERVER_IP}
# DNS annoncé aux PC = le serveur
dhcp-option=6,${SERVER_IP}
dhcp-authoritative
# END-DHCP
