# Tableau de correspondance — commandes du rapport → environnement du labo

Toutes les commandes ci-dessous sont Linux. Le serveur est `192.168.1.1`
(`LAB_NET` modifiable), le domaine local est `tp.local`.

> **Déploiement Wi-Fi partagé (scénario du kit)** : le serveur n'est pas la
> passerelle, il porte l'adresse que lui a donnée le point d'accès (ex.
> `192.168.43.23`). Remplacez donc `192.168.1.1` par cette adresse, et
> interrogez le DNS explicitement : `dig +short web.tp.local @192.168.43.23`.
> Les commandes utilisant `web.tp.local` sans `@IP` supposent que le PC client
> a le serveur comme serveur DNS (voir README §B4).

## 2–3. Diagnostic de connectivité et de chemin

| Commande | Où | Résultat attendu dans le labo |
|---|---|---|
| `ip -br link` | serveur / PC | `eth0` UP |
| `ping -c 4 127.0.0.1` | partout | pile TCP/IP locale OK |
| `ping -c 4 192.168.1.1` | PC | répond (serveur présent) |
| `ping -c 4 8.8.8.8` | serveur / PC | répond si le NAT est actif |
| `ping -c 2 -s 1472 -M do 8.8.8.8` | serveur | échoue si le MTU du chemin < 1500 (VPN, tunnel) |
| `traceroute -n 8.8.8.8` | serveur / PC | liste des routeurs, `* * *` possibles |
| `traceroute -I -n 8.8.8.8` | serveur | même trajet, sondes ICMP |
| `sudo traceroute -T -p 443 example.com` | serveur | traversée des pare-feux qui bloquent l'ICMP |
| `mtr -rwc 50 8.8.8.8` | serveur | perte et latence par saut (rapport) |
| `traceroute -n 10.20.1.5` | `lab.sh up`, dans `h1` | **2 sauts** : r1 puis h2 → vraie démonstration |

## 4. Interfaces et routage

| Commande | Où | Effet |
|---|---|---|
| `ip -br addr` | partout | adresses des interfaces |
| `ip -s link show dev eth0` | serveur | compteurs et erreurs |
| `ip route` | partout | `default via 192.168.1.1` sur les PC |
| `ip route get 8.8.8.8` | serveur | interface réellement utilisée |
| `ip neigh` | partout | cache ARP (le PC voisin apparaît après un ping) |
| `sudo ip addr add 192.168.1.50/24 dev eth0` | PC de test | à faire/retirer en démo (temporaire) |
| `sudo ip link set eth0 up/down` | serveur | couper le lien, voir `ip -br link` |
| `ethtool eth0` / `ethtool -S eth0` | serveur | vitesse négociée, erreurs CRC |
| `sysctl -w net.ipv4.ip_forward=1` | serveur | déjà actif (fichier `99-tp-lab-sysctl.conf`) |
| `ip link add ... type vlan id 20` | serveur | possible mais optionnel (aucun switch 802.1Q dans le labo) |
| `ip rule add ... table 100` | serveur | possible mais optionnel |

## 5. DNS

| Commande | Résultat attendu |
|---|---|
| `dig +short web.tp.local` | `192.168.1.1` |
| `dig +short serveur.tp.local` | `192.168.1.1` |
| `dig +short lab.tp.local` | `192.168.1.50` (nom valide, machine absente → montre que DNS ≠ joignabilité) |
| `dig -x 192.168.1.1` | `serveur.tp.local` (PTR) |
| `dig +short MX gmail.com` | serveurs MX (nécessite Internet) |
| `dig @1.1.1.1 example.com` | compare le résolveur amont au DNS du labo |
| `dig +trace example.com` | délégation depuis la racine (Internet) |
| `nslookup google.com 1.1.1.1` | même chose, outil universel |

**Démo « panne DNS »** (cas 1 version Linux) : `sudo systemctl stop dnsmasq`
→ `ping 8.8.8.8` réussit mais `dig google.com` échoue ; `sudo systemctl start
dnsmasq` rétablit.

## 6. Ports et processus

| Commande | Où | Résultat |
|---|---|---|
| `sudo ss -tulpn` | serveur | 22 sshd, 53 dnsmasq, 80/443 nginx, 5201 iperf3 |
| `ss -s` | partout | statistiques de sockets |
| `ss -tn state established` | partout | connexions TCP en cours |
| `ss -tn state established '( dport = :443 )'` | pendant un `curl` | montre la connexion vers 443 |
| `sudo lsof -i :80` | serveur | processus nginx |
| `sudo lsof -i :5201` | serveur | processus iperf3 |
| `cat /proc/sys/net/ipv4/ip_local_port_range` | partout | plage des ports éphémères |

## 7. Capture de paquets

| Commande | Où | Effet |
|---|---|---|
| `sudo tcpdump -i any -nn -c 20 'port 53'` | serveur, pendant un `dig` | voit la requête **et** la réponse DNS |
| `sudo tcpdump -i any icmp` | serveur, pendant un `ping` depuis un PC | visualise les pings |
| `sudo tcpdump -i any -nn -w capture.pcap` | serveur | enregistre puis `tshark -r capture.pcap -Y dns` |
| `sudo tcpdump -i any 'host 192.168.1.10 and tcp port 443'` | serveur | trafic HTTPS d'un PC précis |
| `sudo tcpdump -i any -nn 'tcp[tcpflags] & tcp-syn != 0'` | serveur | lecture des drapeaux SYN/ACK/FIN/RST |

## 8. nmap

| Commande | Cible | Résultat |
|---|---|---|
| `nmap -sn 192.168.1.0/24` | réseau du labo | serveur + PC allumés |
| `nmap -sT -Pn -p 22,80,443,5201 192.168.1.1` | serveur | 4 ports ouverts |
| `nmap -sV -p 80,443 192.168.1.1` | serveur | nginx + version |
| `sudo nmap -sS -p 1-1024 192.168.1.1` | serveur | scan SYN (root) |
| `sudo nmap -O 192.168.1.1` | serveur | détection OS |
| `nmap -Pn -p 22 192.168.1.50` | nom `lab.tp.local` | hôte absent : « host down » → montre le rôle de `-Pn` |
| `nmap -Pn -p 8080 10.20.1.5` | labo `h1` | ouvert, puis **filtré** après `lab.sh firewall on` |

## 9. Tests applicatifs et débit

| Commande | Résultat |
|---|---|
| `curl -I http://web.tp.local` | `HTTP/1.1 200 OK` |
| `curl -kI https://web.tp.local` | `HTTP/1.1 200 OK` en TLS (certificat auto-signé) |
| `curl -v https://web.tp.local` | détail TLS, en-têtes, redirections |
| `curl -sS -o /dev/null -w 'Code=%{http_code} Temps=%{time_total}s\n' https://web.tp.local` | code + temps total |
| `nc -zv 192.168.1.1 443` | *succeeded* |
| `nc -zv 192.168.1.1 9999` | *refused* (port fermé) |
| `iperf3 -c 192.168.1.1 -t 10` | débit montant |
| `iperf3 -c 192.168.1.1 -R` | débit descendant |
| `iperf3 -c 192.168.1.1 -P 4` | 4 flux parallèles |
| `iperf3 -c 192.168.1.1 -u -b 100M` | test UDP |

## 10. Accès distant et pare-feu

| Commande | Effet |
|---|---|
| `ssh tp@192.168.1.1` | connexion chiffrée (mot de passe `tp2026`) |
| `scp fichier.txt tp@192.168.1.1:/tmp/` | copie vers le serveur |
| `scp tp@192.168.1.1:/var/www/tp-lab/fichier-20m.bin .` | transfert de 20 Mio |
| `ssh -L 8080:localhost:80 tp@192.168.1.1` | puis `http://localhost:8080` |
| `ssh -R 9000:localhost:3000 tp@192.168.1.1` | expose un service local |
| `ssh -D 1080 tp@192.168.1.1` | proxy SOCKS |
| `sudo ufw status verbose` | règles du serveur |
| `sudo ufw allow 22/tcp` | déjà en place |
| `sudo iptables -L -n -v --line-numbers` | compteurs par règle |
| `sudo nft list ruleset` | règles nftables (ufw utilise nft) |
| `sudo iptables -A INPUT -p tcp -s 10.0.50.0/24 --dport 22 -j DROP` | démo à faire **dans le labo**, pas sur le serveur |

> Pare-feu : ne jamais poser un `DROP` par défaut sur un serveur distant sans
> avoir autorisé SSH ; dans ce kit, on démontre le blocage sur le routeur `r1`
> du labo jetable (`lab.sh firewall on`), donc sans risque pour l'accès.

## 11. Les trois cas pratiques

| Cas | Mise en scène dans le kit |
|---|---|
| 1 — « Internet ne marche pas » | `systemctl stop dnsmasq` : `ping 8.8.8.8` OK, `dig google.com` KO → DNS ; puis redémarrage |
| 2 — gros transferts en échec, ping OK | `lab.sh up` : MTU 1400 sur le lien h2 ; `ping -M do -s 1472` échoue, `-s 1372` passe ; `lab.sh mtu-fix on` corrige (clamp MSS) |
| 3 — routeur Linux et blocage SSH | `lab.sh up` + `lab.sh firewall on` : `r1` bloque le port 8080 depuis `10.20.0.0/24`, visible avec `nc`/`nmap` |
