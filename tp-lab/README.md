# Serveur de TP — « Les commandes avancées réseau » (INF3611, Groupe 12)

Kit **Linux** qui transforme un PC du réseau en serveur de laboratoire : tous
les postes, serveur compris, sont connectés au **même point d'accès Wi-Fi**.
Le routeur du point d'accès distribue les adresses et l'accès Internet ; le
serveur, lui, fournit tout ce qu'il faut pour tester **toutes les commandes du
rapport** : DNS, web HTTP/HTTPS, SSH/SCP, iperf3, cibles nmap/tcpdump, pare-feu,
et un labo de routage jetable (cas MTU et blocage).

```
                 Point d'accès Wi-Fi  (routeur : DHCP + Internet)
                 │
   ┌─────────────┼───────────────────────────┐
   │             │                           │
PC SERVEUR   PC CLIENT 1                PC CLIENT 2
192.168.43.23  192.168.43.51            192.168.43.78
│
├── DNS tp.local        53      dig, nslookup
├── web HTTP/HTTPS      80/443  curl, nc, nmap -sV
├── SSH / SCP           22      ssh, scp, tunnels
├── iperf3              5201    iperf3 -c
└── labo namespaces             traceroute multi-sauts, cas 2 et 3
```

> Le serveur **n'est pas** la passerelle : inutile de toucher au routeur du
> point d'accès, sauf pour **désactiver l'isolation des clients** (voir §7).
> Si vous voulez au contraire un serveur-passerelle câblé, voir §8.

## 1. De quoi avez-vous besoin

- 1 PC **Linux** (Ubuntu, Debian ou Linux Mint) pour le serveur, avec `sudo` ;
- 2 PC clients (Linux) ou plus ;
- le **même SSID** pour tous les postes ;
- un point d'accès **sans isolation des clients** (AP isolation) ;
- l'accès Internet, pour `dig example.com`, `traceroute 8.8.8.8`, etc.

Vous n'avez rien à installer à la main : les scripts installent les outils
(`dig`, `nmap`, `tcpdump`, `tshark`, `iperf3`, `nc`, `ethtool`, `lsof`…).

## 2. Partie A — préparer le PC SERVEUR

### A1. Connecter le serveur au Wi-Fi et relever son adresse

```bash
nmcli device status                 # wlan0 doit être « connected »
ip -4 -br addr show                 # ex : 192.168.43.23/24
ip route                            # default via 192.168.43.1
```

Notez cette adresse : c'est `SERVER_IP` pour toute la suite (ici
`192.168.43.23`). Elle doit rester stable pendant la démonstration (§A5).

### A2. Récupérer le kit

```bash
git clone https://github.com/psycho237-prog/labo-tp.git
cd labo-tp/tp-lab
```

### A3. Installer le laboratoire

```bash
sudo ./install.sh
```

Le script détecte l'interface Wi-Fi et passe automatiquement en **mode
`shared`** : il n'active ni DHCP ni NAT (le routeur du point d'accès s'en
charge) et lit l'adresse du serveur sur l'interface.

Ce qu'il installe et configure :

| Élément | Rôle |
|---|---|
| `dnsmasq` | DNS de la zone `tp.local` (`web.tp.local`, `serveur.tp.local`…) |
| `nginx` + certificat auto-signé | site HTTP 80 et HTTPS 443 |
| `openssh-server` + compte `tp` | SSH/SCP et tunnels |
| `iperf3.service` | serveur de débit sur 5201 |
| `ufw` | n'ouvre ces ports qu'au réseau du point d'accès |

À la fin, le résumé doit afficher :

```
 mode : shared
 Adresse du serveur    : 192.168.43.23  (wlan0)
 Rôle réseau           : hôte du point d'accès — DHCP et Internet fournis par son routeur
```

Si l'adresse détectée n'est pas la bonne, forcez-la :

```bash
sudo SERVER_IP=192.168.43.23 ./install.sh
```

### A4. Vérifier le serveur

```bash
systemctl status dnsmasq nginx iperf3 ssh --no-pager
sudo ./tests/run-all-tests.sh
```

Le script rejoue toutes les commandes du rapport, journalise chaque sortie dans
`tests/journal/<date>/` et affiche un tableau OK / ÉCHEC. Le labo de routage
(namespaces) n'est pas nécessaire pour cette étape.

### A5. Rendre l'adresse du serveur stable

Une adresse DHCP peut changer et casser les commandes des PC clients. Choisissez
**une** des deux solutions :

- **réservation DHCP** sur le routeur du point d'accès (adresse MAC du serveur
  → toujours la même IP) — recommandé ;
- ou adresse fixe sur le serveur, en dehors de la plage DHCP du routeur :

```bash
nmcli connection show                       # nom du profil Wi-Fi
sudo nmcli connection modify "<profil>" ipv4.addresses 192.168.43.23/24 ipv4.method manual
sudo nmcli connection up "<profil>"
```

> Attention : une IP fixe mal choisie (déjà utilisée, hors sous-réseau) coupe
> l'accès Wi-Fi du serveur. En cas de doute, gardez le DHCP + réservation.

### A6. (Optionnel) labo de routage, MTU et pare-feu

```bash
sudo ./lab/lab.sh up          # h1 10.20.0.10 → r1 → h2 10.20.1.5 (MTU 1400)
sudo ./lab/lab.sh status
sudo ./lab/lab.sh down        # nettoyage
```

Sert aux cas pratiques 2 et 3 du rapport, sans machine virtuelle ni câble.

## 3. Partie B — préparer chaque PC CLIENT

### B1. Connecter le PC au même point d'accès

```bash
nmcli device wifi list
nmcli device wifi connect "<SSID>" password "<mot de passe>"
ip -4 -br addr                # adresse du même sous-réseau que le serveur
ping -c 4 <SERVER_IP>         # doit répondre
```

### B2. Préparer et tester le poste en une commande

```bash
git clone https://github.com/psycho237-prog/labo-tp.git
cd labo-tp/tp-lab
sudo SERVER_IP=<SERVER_IP> ./scripts/setup-client.sh
```

Le script installe les outils manquants, renouvelle le bail DHCP, puis teste :
même sous-réseau, ping du serveur, DNS `tp.local`, port 443, HTTPS, débit
iperf3. Il termine par `PC CLIENT PRÊT` avec `0 échec` et la liste des
commandes de démonstration.

Pour ne rien modifier (simple contrôle avant la soutenance) :

```bash
sudo SERVER_IP=<SERVER_IP> ./scripts/setup-client.sh --check
```

### B3. Vérifications manuelles (équivalent)

```bash
ip -4 -br addr                                        # même sous-réseau que le serveur
ping -c 4 <SERVER_IP>
dig +short web.tp.local @<SERVER_IP>                  # DNS du labo
curl -kI -H 'Host: web.tp.local' https://<SERVER_IP>/ # web HTTPS
nc -zv <SERVER_IP> 443
iperf3 -c <SERVER_IP> -t 10
ssh tp@<SERVER_IP>                                    # mot de passe : tp2026
```

### B4. Faire résoudre `web.tp.local` sans `@<SERVER_IP>` (optionnel)

Par défaut, les PC utilisent le DNS du routeur, qui ne connaît pas la zone
`tp.local`. Deux façons de faire :

- ponctuel : `dig +short web.tp.local @<SERVER_IP>` (utilisé par les scripts) ;
- durable : mettre le DNS du PC sur l'adresse du serveur
  (`nmcli connection modify "<profil>" ipv4.dns <SERVER_IP> ipv4.ignore-auto-dns yes`
  puis `nmcli connection up "<profil>"`) — à rétablir après la démonstration.

## 4. Vérification finale avant la soutenance

```bash
# sur le serveur
systemctl is-active dnsmasq nginx iperf3 ssh
sudo ./tests/run-all-tests.sh

# sur chaque PC client
sudo SERVER_IP=<SERVER_IP> ./scripts/setup-client.sh --check
```

Attendu : tous les services `active`, un tableau OK pour les tests, et
`0 échec` sur chaque PC client. Faire ce contrôle **10 minutes avant** de
présenter, sur le réseau réel de la salle.

## 5. Adresses, noms et ports

| Élément | Valeur |
|---|---|
| Adresses des PC | distribuées par le routeur du point d'accès |
| Adresse du serveur | celle de son interface Wi-Fi (ex. `192.168.43.23`) |
| Noms locaux | `web.tp.local`, `serveur.tp.local`, `dns.tp.local`, `lab.tp.local` |
| Compte de démo | `tp` / `tp2026` (SSH, SCP) |
| Labo namespaces | `h1` 10.20.0.10 → `r1` → `h2` 10.20.1.5, MTU 1400 |

| Service | Port | Test |
|---|---|---|
| DNS | 53 | `dig +short web.tp.local @<SERVER_IP>` |
| HTTP | 80 | `curl -I http://<SERVER_IP>/` |
| HTTPS | 443 | `curl -kI https://<SERVER_IP>/` |
| SSH/SCP | 22 | `nc -zv <SERVER_IP> 22`, `ssh tp@<SERVER_IP>` |
| iperf3 | 5201 | `iperf3 -c <SERVER_IP> -t 10` |

## 6. Dépannage

| Symptôme | Cause probable | Solution |
|---|---|---|
| Les PC ont Internet mais ne joignent pas le serveur | **isolation des clients** activée sur le point d'accès | désactiver « AP isolation / client isolation » dans l'interface du routeur |
| L'adresse du serveur change | bail DHCP non réservé | §A5 : réserver l'adresse |
| `dig web.tp.local` échoue sans `@IP` | le PC utilise le DNS du routeur | utiliser `@<SERVER_IP>` ou §B4 |
| `curl` HTTPS refuse le certificat | certificat auto-signé | `curl -k`, et l'expliquer pendant l'exposé |
| `dnsmasq` ne démarre pas | port 53 occupé par systemd-resolved | `sudo ss -lunp 'sport = :53'`, puis relancer `install.sh` |
| `iperf3` : *Connection refused* | service arrêté | `sudo systemctl restart iperf3` |
| `nmap -sn` ne voit que le serveur | isolation des clients / ICMP filtré | désactiver l'isolation, ou `nmap -Pn` |
| `nmcli` ne trouve pas le Wi-Fi | carte désactivée ou RF-kill | `nmcli radio wifi on`, `rfkill list` |
| Plus d'accès Wi-Fi après une IP fixe | adresse hors sous-réseau ou conflit | remettre le DHCP : `sudo nmcli connection modify "<profil>" ipv4.method auto` |

Journaux : `journalctl -u dnsmasq -n 30`, `journalctl -u nginx`,
`journalctl -u iperf3`, `sudo nginx -t`, `sudo dnsmasq --test`.

## 7. Point d'attention : l'isolation des clients

Beaucoup de points d'accès (surtout en salle de cours) interdisent par défaut
les échanges **entre** postes connectés : le serveur est joignable par
Internet mais pas par les PC voisins. C'est la première chose à vérifier si
`ping <SERVER_IP>` échoue alors que le Wi-Fi « fonctionne ». Réglages usuels :

- box / routeur : « Isolation des clients », « AP isolation », « Séparation
  des invités » à désactiver ;
- réseau « invité » : souvent isolé par conception → utiliser le réseau
  principal ;
- portail captif de l'établissement : peut bloquer aussi, prévoir un point
  d'accès personnel.

## 8. Mode avancé : serveur-passerelle câblé (hors scénario Wi-Fi)

Pour un labo **isolé** où le serveur est la passerelle et le DHCP (deux cartes
réseau : câble pour le labo, Wi-Fi pour Internet) :

```bash
sudo LAB_IF=eth0 UPLINK_IF=wlan0 ./install.sh        # passerelle + NAT
sudo MODE=gateway LAB_IF=eth0 UPLINK_IF= ./install.sh # isolé, sans NAT
```

Le DHCP distribue alors `x.x.x.100`–`x.x.x.200`, les PC ont pour passerelle et
DNS l'adresse du serveur (`192.168.1.1` par défaut), et `web.tp.local` résout
directement. `scripts/set-ip.sh` fixe l'adresse du serveur sur le câble.

## 9. Sécurité et légalité (à rappeler pendant l'exposé)

- Le pare-feu n'ouvre les services qu'**au réseau du point d'accès**, pas à
  Internet ; vérifier avec `sudo ufw status verbose`.
- Le compte `tp` / `tp2026` est un compte de démonstration : mot de passe à
  changer, jamais réutilisé ailleurs.
- Certificat auto-signé assumé et expliqué : c'est un laboratoire.
- `nmap`, `tcpdump` et les tests de débit uniquement sur **ses** machines ou
  avec autorisation écrite.

## 10. Retour arrière

```bash
sudo ./uninstall.sh
```

Retire services et configurations du labo, les règles ufw ajoutées et les noms
de `/etc/hosts` (les paquets et le compte `tp` restent). Pour remettre le PC en
DHCP : `sudo nmcli connection modify "<profil>" ipv4.method auto && sudo nmcli
connection up "<profil>"`.

## 11. Contenu du kit

```
tp-lab/
├── install.sh                     # provisionne le serveur (mode Wi-Fi partagé par défaut)
├── uninstall.sh                   # retire tout
├── scripts/
│   ├── setup-client.sh            # prépare un PC client (outils + DHCP + tests)
│   └── set-ip.sh                  # adresse fixe du serveur (mode câblé)
├── config/
│   ├── dnsmasq.conf.tpl           # zone tp.local + bloc DHCP (retiré en mode partagé)
│   ├── nginx-tp-lab.conf          # site HTTP/HTTPS
│   ├── iperf3.service             # serveur de débit
│   ├── 99-tp-lab-sysctl.conf      # ip_forward (mode passerelle)
│   └── 40-tp-lab-netplan.yaml.tpl # modèle d'adresse fixe
├── lab/lab.sh                     # labo namespaces (routage, MTU, pare-feu)
├── tests/run-all-tests.sh         # rejoue toutes les commandes du rapport
└── docs/
    ├── COMMANDES.md               # commande → où et comment la tester
    └── PRESENTATION.md            # déroulé de la démonstration
```
