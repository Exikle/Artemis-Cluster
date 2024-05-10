# Artemis Cluster

Repo to track my setup and deployment of my K3S Cluster. This is in no ways "ideal" or "production ready" but it works for me

---

#### Resources

- [1] <https://github.com/ChristianLempa/cheat-sheets/blob/main/kubernetes/k3s.md>
- [2] <https://www.putorius.net/custom-motd-login-screen-linux.html>

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

##### NODE PREP

````bash
sudo qm create 8000 --name "ubuntu-cloudinit" --ostype l26 \
    --memory 1024 \
    --agent 1 \
    --bios ovmf --machine q35 --efidisk0 local-ceph-01:0,pre-enrolled-keys=0 \
    --cpu host --socket 1 --cores 1 \
    --vga serial0 --serial0 socket  \
    --net0 virtio,bridge=vmbr0

sudo qm importdisk 8000 mantic-server-cloudimg-amd64.img local-ceph-01
sudo qm set 8000 --scsihw virtio-scsi-pci --virtio0 local-ceph-01:vm-8000-disk-1,discard=on
sudo qm set 8000 --boot order=virtio0
sudo qm set 8000 --ide2 local-ceph-01:cloudinit

sudo qm set 8000 --cicustom "vendor=local:snippets/vendor.yaml"
sudo qm set 8000 --tags template,23.10,cloudinit,ubuntu
sudo qm set 8000 --ciuser root
sudo qm set 8000 --cipassword $(openssl passwd -6 $CLEARTEXT_PASSWORD)
sudo qm set 8000 --sshkeys ~/.ssh/authorized_keys
sudo qm set 8000 --ipconfig0 ip=dhcp

qm clone 8000  201 --name k3s-02 --full
qm clone 8000  202 --name k3s-02 --full
qm clone 8000  203 --name k3s-03 --full
qm clone 8000  204 --name k3s-04 --full
qm clone 8000  205 --name k3s-05 --full

qm resize 201 virtio0 +12.5G
qm resize 202 virtio0 +12.5G
qm resize 203 virtio0 +12.5G
qm resize 204 virtio0 +12.5G
qm resize 205 virtio0 +12.5G
````

Created a cloud init drive and set some parametes so we could clone the drives. Gave each node 16GB

###### TODO

- use ansible for node setup

###### NOTE

On one of the nodes there was issues pinging so ran the following:

`````bash
cd /var/lib/dpkg/info/ && sudo apt install --reinstall $(grep -l 'setcap' * | sed -e 's/\.[^.]*$//g' | sort --unique)
``````

#### Pfsense

- Register IP 10.10.99.4 under the LAB VLAN as a VIP
- Create 5 static IPs based on the MAC address of the above

#### TrueNAS

see storage/Readme.md

## Setup

Setting up the 3 control planes with etcd and 2 agents in one cluster

On Node 01 (K3S-01) run the following

`openssl rand -hex 10 > k3s_secret.txt`

You will need to copy that file or create it on each node and copy the contents over.

##### First Server Prep

````bash
curl -sfL https://get.k3s.io | K3S_TOKEN=`cat k3s_secret.txt` sh -s - server \
--cluster-init \
--disable=servicelb
````

##### Additional Control Planes

````bash
curl -sfL https://get.k3s.io | K3S_TOKEN=`cat k3s_secret.txt` sh -s - server \
--server https://10.10.99.201:6443 \
--disable=servicelb
````

Agents

````bash
curl -sfL https://get.k3s.io | K3S_TOKEN=`cat k3s_secret.txt` sh -s - agent \
--server https://10.10.99.201:6443
````

## Post-Setup

`kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.4/config/manifests/metallb-native.yaml`

Apply networking in the following order

1.      metallb (README exists)
2.      traefik (to override some default values)
3.      ingress and cert manager, read README  there to make sure you're good

TODO

COMPLETE | TASK
---|---
FALSE| move secrets out of files and into its own secrets.yaml/ .env
FALSE| redeploy all iceboxed apps
FALSE| commit to github all the changes since years ago


Deployment Checklist

-
- Persistent Volume Claim has suffix "-pvc"
- Service has suffix "-pvc"
- Ingress Route has suffix "-ing-r

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

```mermaid

graph TD;

initial>Kustomization: Init] --> |Creates| k-ac>Kustomization: artemis-cluster];
initial>Kustomization: Init] --> |Creates| k-cm>Kustomization: cert-manager];
initial>Kustomization: Init] --> |Creates| k-dc>Kustomization: democratic-csi];
initial>Kustomization: Init] --> |Creates| k-ext-secrets>Kustomization: external-secrets];
initial>Kustomization: Init] --> |Creates| k-ext-svc>Kustomization: external-services];
initial>Kustomization: Init] --> |Creates| k-fs>Kustomization: flux-system];
initial>Kustomization: Init] --> |Creates| k-ks>Kustomization: kube-system];
initial>Kustomization: Init] --> |Creates| k-ms>Kustomization: metallb-sytem];

k-ac>Kustomization: artemis-cluster] -->|Depends on| h-homepage(HelmRelease: *app);

k-cm>Kustomization: cert-manager] --> |Creates| k-cm-app>Kustomization: cert-manager app];
k-cm>Kustomization: cert-manager] --> |Creates| k-cm-issuers>Kustomization: cert-manager issuers];
k-cm>Kustomization: cert-manager] --> |Creates| k-cm-certs>Kustomization: cert-manager certs];
k-cm-app>Kustomization: App] --> |Depends on| k-ks-traefik>Kustomization: Traefik];
k-cm-issuers>Kustomization: Issuers] --> |Depends on| k-cm-app>Kustomization: App];
k-cm-certs>Kustomization: Certs] --> |Depends on| k-cm-issuers>Kustomization: Issuers];
k-cm-certs>Kustomization: Certs] --> |Depends on| k-ks-reflector>Kustomization: Reflector];

k-dc>Kustomization: democratic-csi] --> |Creates| k-dc-appdata(HelmRelease: Appdata);
k-dc-appdata(HelmRelease: Appdata) --> |Depends on| k-ks-traefik>Kustomization: Traefik];

k-ext-secrets>Kustomization: external-secrets] --> |Creates| k-ext-secrets-app>Kustomization: App];
k-ext-secrets>Kustomization: external-secrets] --> |Creates| k-ext-secrets-bw>Kustomization: Bitwarden-ESO];
k-ext-secrets-bw>Kustomization: Bitwarden-ESO] --> |Creates| k-ext-secrets-bw-app>Kustomization: Bitwarden-ESO-App];
k-ext-secrets-bw>Kustomization: Bitwarden-ESO] --> |Creates| k-ext-secrets-bw-pre>Kustomization: Bitwarden-ESO-Pre];
k-ext-secrets-bw>Kustomization: Bitwarden-ESO] --> |Creates| k-ext-secrets-bw-secrets>Kustomization: Bitwarden-ESO-Secrets];
k-ext-secrets-bw>Kustomization: Bitwarden-ESO] --> |Creates| k-ext-secrets-bw-stores>Kustomization: Bitwarden-ESO-Stores];

k-ext-secrets-bw-app>Kustomization: Bitwarden-ESO-App`] --> |Depends on| k-ext-secrets-bw-pre>Kustomization: Bitwarden-ESO-Pre];
k-ext-secrets-bw-pre>Kustomization: BW Pre] --> |Depends on| k-ext-secrets-app>Kustomization: App];
k-ext-secrets-bw-secrets>Kustomization: Bitwarden-ESO-Secrets] --> |Depends on| k-ext-secrets-bw-stores>Kustomization: Bitwarden-ESO-Stores];
k-ext-secrets-bw-stores>Kustomization: Bitwarden-ESO-Stores]--> |Depends on| k-ext-secrets-app>Kustomization: App];

k-ext-svc>Kustomization: external-services] --> |Creates| ingress(Ingress Routes - External);

k-fs>Kustomization: flux-system] --> |Creates| k-fs-capacitor(HelmRelease: Capacitor);

k-ks>Kustomization: kube-system] --> |Creates| k-ks-traefik>Kustomization: Traefik]
k-ks>Kustomization: kube-system] --> |Creates| k-ks-traefik-dash>Kustomization: Traefik Dash]
k-ks>Kustomization: kube-system] --> |Creates| k-ks-reflector>Kustomization: Reflector]
k-ks>Kustomization: kube-system] --> |Creates| k-ks-reloader>Kustomization: Reloader]

k-ks-traefik-dash>Kustomization: Traefik Dash] --> |Depends on| k-ks-traefik>Kustomization: Traefik];


```

k-ac>Kustomization: artemis-cluster] -->|Depends on| h-homepage(HelmRelease: homepage);
k-ac>Kustomization: artemis-cluster] -->|Depends on| h-nzbhydra2(HelmRelease: nzbhydra2);
k-ac>Kustomization: artemis-cluster] -->|Depends on| h-sonarr(HelmRelease: sonarr);
k-ac>Kustomization: artemis-cluster] -->|Depends on| h-radarr(HelmRelease: radarr);
k-ac>Kustomization: artemis-cluster] -->|Depends on| h-sabnzbd(HelmRelease: sabnzbd);
k-ac>Kustomization: artemis-cluster] -->|Depends on| h-overseerr(HelmRelease: overseerr);
