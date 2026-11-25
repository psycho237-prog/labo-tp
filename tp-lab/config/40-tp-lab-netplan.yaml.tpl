# =============================================================================
#  TP INF3611 — adresse fixe du serveur (Ubuntu Server / Netplan)
#  À copier dans /etc/netplan/40-tp-lab.yaml puis : sudo netplan apply
#  Remplacer ${LAB_IF} par l'interface filaire réelle (ip -br link).
#  renderer: networkd  (Ubuntu Server)  —  NetworkManager si bureau.
# =============================================================================
network:
  version: 2
  renderer: networkd
  ethernets:
    ${LAB_IF}:
      dhcp4: no
      addresses: [${SERVER_IP}/24]
      # pas de passerelle ici : c'est le serveur qui EST la passerelle du labo
      optional: true
