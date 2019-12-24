

# Artemis Cluster Configuration
Deployment files for my Kubernetes cluster "Artemis-Cluster".

This is to replace my UNRAID server as the primary media machine turning UNRAID into a machine specifically for domain user storage.

The new cluster will host media, web hosting and connect to various metric services.

|Machine|Minimum Specs|
|--|--|
|`Master`| `2 GB RAM` `2 Cores of CPU`
|`Node`| `1 GB RAM` `1 Core of CPU`

## Prerequisites

The following steps have to be executed on both the master and node machines.

#### Install OpenSSH-Server
    $ sudo apt-get install openssh-server
    $ sudo apt-get install net-tools

First, login as ‘sudo’ user because the following set of commands need to be executed with ‘sudo’ permissions. Then, update your ‘apt-get’ repository.

#### Turn off Swap
    $ sudo su
    # swapoff -a
    # nano /etc/fstab
    # exit

Comment out the swap line with "#", then press ‘Ctrl+X’, then press ‘Y’ and then press ‘Enter’ to Save the file.

#### Update The Hostnames

Make sure the host name in `/etc/hostname` is the machine name

#### Set Static IPs

Proxmox + Node `10.10.0.200`
Master:  `10.10.0.201`
Worker: `10.10.0.20(1+X)`

Run the following command on both machines to check current IP addresses of each.

    $ ifconfig

 Edit `/etc/hosts`, add all the nodes and their ips, then press ‘Ctrl+X’, then press ‘Y’ and then press ‘Enter’ to Save the file.

    $ sudo nano /etc/hosts

After this, restart your machine(s).

#### Install Docker
    $ sudo apt-get update
    $ sudo apt-get install \
        apt-transport-https \
        ca-certificates \
        curl \
        gnupg-agent \
        software-properties-common
    $ curl -fsSL https://download.docker.com/linux/debian/gpg | sudo apt-key add -
    $ sudo apt-key fingerprint 0EBFCD88
    $ sudo add-apt-repository \
       "deb [arch=amd64] https://download.docker.com/linux/ubuntu \
       $(lsb_release -cs) \
       stable"
    $ apt-cache madison docker-ce
    $ sudo apt-get install -y docker-ce=5:18.09.9~3-0~ubuntu-bionic docker-ce-cli=5:18.09.9~3-0~ubuntu-bionic containerd.io
    $ sudo su
    # cat > /etc/docker/daemon.json <<EOF
    {
      "exec-opts": ["native.cgroupdriver=systemd"],
      "log-driver": "json-file",
      "log-opts": {
        "max-size": "100m"
      },
      "storage-driver": "overlay2"
    }
    EOF
    # mkdir -p /etc/systemd/system/docker.service.d
    # systemctl daemon-reload
    # systemctl restart docker
    # exit

Next we have to install these 3 essential components for setting up Kubernetes environment: kubeadm, kubectl, and kubelet.

Run the following commands before installing the Kubernetes environment.

    $ sudo su
    # curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
    # cat <<EOF >/etc/apt/sources.list.d/kubernetes.list
    deb http://apt.kubernetes.io/ kubernetes-xenial main
    EOF
    # apt-get update && apt-get install -qy kubelet=1.17.0-00 kubectl=1.17.0-00 kubeadm=1.17.0-00
    # exit

## Master Setup Instructions

    $ sudo kubeadm init --apiserver-advertise-address=10.10.0.201 --pod-network-cidr=10.244.0.0/16
    $ mkdir -p $HOME/.kube
    $ sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
    $ sudo chown $(id -u):$(id -g) $HOME/.kube/config
    $ kubectl apply -f https://github.com/coreos/flannel/raw/master/Documentation/kube-flannel.yml
    $ kubectl taint nodes --all node-role.kubernetes.io/master-

## Node Setup Instructions

Copy the join command's out put, should look something like this:

    $ sudo kubeadm join 10.10.0.201:6443 --token randomtoken \
        --discovery-token-ca-cert-hash sha256:randomhash -v=5

Run it on a node to join the node.

**IF RESET** necessary, run the following to make life easier as root


    kubeadm reset && \
    systemctl stop kubelet && \
    systemctl stop docker && \
    rm -rf /var/lib/cni/ && \
    rm -rf /var/lib/kubelet/* && \
    rm -rf /etc/cni/ && \
    ifconfig cni0 down && \
    ifconfig flannel.1 down && \
    ifconfig docker0 down && \
    ip link delete cni0 && \
    ip link delete flannel.1 && \
    systemctl start docker && \
    systemctl start kubelet






## Todo / Roadmap

Kubernetes Cluster Setup + Migration (from PRD001L)

1. Build cluster (10.10.0.200+ for ip range), will update this list every time a new node is added
    - PRD002L -> to become PKN001L, currently a proxmox node
      -  10.10.0.200
    - PKN002L (Master)
	    - 10.10.0.201
    - PKN003L
	    - 10.10.0.202
    - PKN004L
	    - 10.10.0.203
    - VKN005L -> running off of Unraid server
	    - 10.10.0.204

**STATUS**: Complete

2. Deploy Rook-Ceph storage
    - [x] Ceph-Cluster
    - [x] Filesystem
    - [x] PVC
    - [x] Storage-Class

**STATUS**: Complete

3. Setup Ingress so http://subdomain.dcunhahome.com -> Cluster pods

**STATUS**: Complete

4. Migrate dockers from PRD001L

|DOCKER|MIGRATED|RUNNING|COMMENTS
|--|--|--|--|
|Heimdall|YES|NO|
|Radarr|YES|NO|
|Sabnzbd|YES|NO|
|DelugeVPN|YES|NO|
|Sonarr|YES|NO|
|Plex|NO|NO|
|Jackett|YES|NO|
|Ombi|YES|NO|
|Tautulli|YES|NO|
|Sonarr|YES|NO|
|Unmanic|YES|NO|Will wait till PRD001L is up to deploy|

  **STATUS**: In-Progress

5. Possible new pods
    - Prometheus
    - Searchlight


  **STATUS**: Not Started
