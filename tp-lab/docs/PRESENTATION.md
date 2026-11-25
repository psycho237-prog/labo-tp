# Déroulé de la démonstration (≈ 25 min)

Pré-requis : serveur et PC clients connectés au **même point d'accès Wi-Fi**,
serveur démarré (`install.sh`), `lab.sh up` lancé, PC préparés avec
`sudo SERVER_IP=<IP serveur> ./scripts/setup-client.sh`, un terminal sur le
serveur et un sur un PC. Vérifier avant de commencer que `ping <IP serveur>`
fonctionne depuis chaque PC (sinon : isolation des clients, README §7).

> Astuce : `sudo ./tests/run-all-tests.sh` affiche d'abord le résultat de
> toutes les commandes. Le déroulé ci-dessous reprend les mêmes commandes une
> par une pour expliquer chaque sortie.

## 0. Introduction (2 min)

1. Montrer le schéma : `README.md`, section 1.
2. Plan d'adressage : serveur `192.168.1.1`, plage DHCP `.100–.200`,
   domaine `tp.local`.
3. Rappeler la problématique du rapport : trouver **à quelle étape** la
   connexion échoue, puis la réparer.

```bash
ip -br addr           # serveur : 192.168.1.1/24
ip route              # default via <uplink>
```

Sur un PC client :

```bash
ip -br addr           # adresse obtenue en DHCP
ip route              # default via 192.168.1.1
```

## 1. Couche physique et liaison (2 min)

```bash
ip -br link
ethtool eth0                 # vitesse, duplex, « Link detected: yes »
ethtool -S eth0 | head -20   # erreurs, collisions
ip neigh                     # cache ARP : faire un ping avant pour le remplir
```

Message : « le lien est-il actif ? » — première question de la méthode §11.

## 2. Réseau : adresse et route (2 min)

```bash
ping -c 4 127.0.0.1          # pile locale
ping -c 4 192.168.1.1        # serveur joignable
ip route get 8.8.8.8         # route réellement choisie
ping -c 4 8.8.8.8            # Internet (si NAT)
```

Sur le PC : `ping -c 4 192.168.1.1`, `ip route`.

## 3. Chemin et MTU (3 min)

```bash
traceroute -n 8.8.8.8
traceroute -I -n 8.8.8.8
mtr -rwc 5 8.8.8.8
ping -c 2 -M do -s 1472 8.8.8.8     # test du MTU 1500
```

Commenter les `* * *` : un routeur peut filtrer sans être en panne.
Puis la démonstration **labo** avec un vrai saut intermédiaire :

```bash
sudo ip netns exec h1 traceroute -n 10.20.1.5   # 2 sauts : r1, puis h2
```

## 4. DNS (3 min)

```bash
dig +short web.tp.local          # 192.168.1.1
dig +short lab.tp.local          # 192.168.1.50 : nom valide, machine absente
dig -x 192.168.1.1               # PTR
dig +short MX gmail.com
dig @1.1.1.1 example.com         # résolveur précis
nslookup google.com 1.1.1.1
dig +trace example.com | head -20
```

**Panne DNS en direct** (cas 1, version Linux) :

```bash
sudo systemctl stop dnsmasq
ping -c 2 8.8.8.8                # OK
dig google.com                    # échec : le nom ne résout plus
sudo systemctl start dnsmasq
dig google.com                    # rétabli
```

Conclusion : « la 4e étape (nom) échoue alors que la 3e (adresse) passe ».

## 5. Ports et processus (2 min)

```bash
sudo ss -tulpn                   # 22, 53, 80, 443, 5201
sudo lsof -i :80
curl -kI https://web.tp.local &  # en arrière-plan
ss -tn state established '( dport = :443 )'
```

## 6. Capture de paquets (3 min)

Terminal 1 :

```bash
sudo tcpdump -i any -nn -c 10 'port 53'
```

Terminal 2 : `dig +short example.com` → on voit la requête **et** la réponse.

Puis enregistrement et relecture :

```bash
sudo tcpdump -i any -nn -w capture.pcap icmp   # lancer un ping dans un autre terminal
tshark -r capture.pcap -Y icmp
```

Insister sur la différence **filtre de capture** (BPF) / **filtre d'affichage**.

## 7. nmap (3 min)

```bash
nmap -sn 192.168.1.0/24                  # inventaire du labo
nmap -sT -Pn -p 22,80,443,5201 192.168.1.1
nmap -sV -p 80,443 192.168.1.1
sudo nmap -sS -p 1-1024 192.168.1.1
nmap -Pn -p 22 192.168.1.50              # host down : rôle de -Pn
```

Rappeler le **cadre légal** : uniquement ses machines.

## 8. Applicatif et débit (3 min)

```bash
curl -I http://web.tp.local
curl -kI https://web.tp.local
curl -sS -k -o /dev/null -w 'Code=%{http_code} Temps=%{time_total}s\n' https://web.tp.local
nc -zv 192.168.1.1 443
nc -zv 192.168.1.1 9999        # refusé
iperf3 -c 192.168.1.1 -t 10
iperf3 -c 192.168.1.1 -R
```

Depuis un PC : `iperf3 -c 192.168.1.1 -t 10` → mesurer le débit réel du lien.

## 9. Accès distant (2 min)

```bash
ssh tp@192.168.1.1                 # mot de passe : tp2026
exit
scp tp@192.168.1.1:/var/www/tp-lab/fichier-20m.bin /tmp/
ssh -L 8080:localhost:80 tp@192.168.1.1   # puis http://localhost:8080
```

## 10. Pare-feu et les trois cas pratiques (4 min)

Cas 1 déjà vu (DNS).

**Cas 2 — MTU** :

```bash
sudo ip netns exec h1 ping -c 2 -M do -s 1472 10.20.1.5   # échoue
sudo ip netns exec h1 ping -c 2 -M do -s 1372 10.20.1.5   # passe
sudo ./lab/lab.sh mtu-fix on                              # correction MSS
```

**Cas 3 — blocage d'un flux routé** :

```bash
sudo ip netns exec h1 nc -zv 10.20.1.5 8080     # ouvert
sudo ./lab/lab.sh firewall on
sudo ip netns exec h1 nc -zv 10.20.1.5 8080     # expiré : DROP sur r1
sudo ip netns exec h1 nmap -Pn -p 8080 10.20.1.5 # « filtered »
sudo ./lab/lab.sh firewall off
```

Montrer les règles : `sudo ip netns exec r1 iptables -S FORWARD`.

Puis sur le serveur :

```bash
sudo ufw status verbose
sudo iptables -L -n -v --line-numbers
sudo nft list ruleset | head -30
sysctl net.ipv4.ip_forward
```

## 11. Conclusion (1 min)

Reprendre la chaîne du rapport : lien → adresse/route → chemin → nom → port →
service. Chaque outil répond à une seule question, et l'ordre évite de
« réparer au hasard ». Terminer sur les bonnes pratiques (autorisation,
sauvegarde de la configuration avant modification, captures non diffusées).

## Nettoyage après la présentation

```bash
sudo ./lab/lab.sh down          # retire namespaces, services et règles
```
