# labo-tp — TP INF3611 « Les commandes avancées réseau »

Kit Linux pour monter un serveur de laboratoire sur un réseau local Wi-Fi :
tous les postes (serveur et clients) sont connectés au **même point d'accès**,
et le serveur fournit les services nécessaires pour tester toutes les
commandes du rapport (DNS `tp.local`, web HTTP/HTTPS, SSH/SCP, iperf3, cibles
nmap/tcpdump, pare-feu), plus un labo de routage jetable pour les cas MTU et
blocage.

- **Installation et mode d'emploi complets : [`tp-lab/README.md`](tp-lab/README.md)**
- Rapport d'exposé : `Rapport d'exposé - Les commandes avancées réseau (1).pdf`

## Démarrage rapide

Sur le PC serveur, connecté au Wi-Fi :

```bash
cd tp-lab
sudo ./install.sh                     # mode « réseau partagé » détecté automatiquement
sudo ./tests/run-all-tests.sh         # rejoue toutes les commandes du rapport
```

Sur chaque PC client, connecté au même point d'accès :

```bash
cd tp-lab
sudo SERVER_IP=<adresse du serveur> ./scripts/setup-client.sh
```

## Contenu

```
tp-lab/
├── install.sh            # provisionne le serveur
├── uninstall.sh          # retour arrière
├── scripts/              # setup-client.sh (PC client), set-ip.sh (mode câblé)
├── config/               # dnsmasq, nginx, iperf3, sysctl, netplan
├── lab/lab.sh            # labo namespaces : routage, MTU, pare-feu
├── tests/run-all-tests.sh# toutes les commandes du rapport, journalisées
└── docs/                 # correspondance des commandes, déroulé de présentation
```
