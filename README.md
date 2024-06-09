#



---



## Pre-Setup

#### Proxmox

Create 5 nodes, we'll be doing 3 control planes with etcd and 2 agents

Current setup is as follows:

Node | Hostname | Static IP
---|---|---
01| k3s01 | 10.10.99.201
02| k3s02 | 10.10.99.202
03| k3s03 | 10.10.99.203
04| k3s04 | 10.10.99.204
05| k3s05 | 10.10.99.205



###### TODO

- use ansible for node setup

``````

#### Pfsense

- Register IP 10.10.99.4 under the LAB VLAN as a VIP
- Create 5 static IPs based on the MAC address of the above

Apps Checklist

APP         |DE-ICED    |DEPLOYMENT | PVC   | Service   | Ingress Route
---         |---        |---        |---    |---        |---
grafana     | NEW       | TRUE      | TRUE  | TRUE      | TRUE
nginx       | NEW       | FALSE     | FALSE | FALSE     | FALSE
nzbhydra2   | NEW       | FALSE     | FALSE | FALSE     | FALSE
overseer    | NEW       | FALSE     | FALSE | FALSE     | FALSE
plex        | TRUE      | FALSE     | FALSE | FALSE     | FALSE
radarr      | TRUE      | FALSE     | FALSE | FALSE     | FALSE
sabnzbd     | TRUE      | FALSE     | FALSE | FALSE     | FALSE
deluge      | FALSE     | FALSE     | FALSE | FALSE     | FALSE
duskbot     | FALSE     | FALSE     | FALSE | FALSE     | FALSE
jackett     | FALSE     | FALSE     | FALSE | FALSE     | FALSE
minecraft   | FALSE     | FALSE     | FALSE | FALSE     | FALSE
tautulli    | FALSE     | FALSE     | FALSE | FALSE     | FALSE
unifi       | FALSE     | FALSE     | FALSE | FALSE     | FALSE
unmanic     | FALSE     | FALSE     | FALSE | FALSE     | FALSE

External App Ingress Routes

APP         | ROUTED
---         |---
HAOS        | FALSE
PIHOLE      | TRUE
UNIFI       | TRUE
PVE         | FALSE
PFSENSE     | FALSE
TRUENAS     | TRUENAS
DELL SW     | FALSE
MIKROTIK    | FALSE

