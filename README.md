
# Artemis-Cluster
Deployment files for my Kubernetes cluster "Artemis-Cluster"

Master: (10.10.0.205)
2 GB RAM2 Cores of CPU

Slave/ Node: (10.10.0.20X)
1 GB RAM1 Core of CPU


#### **Install OpenSSH-Server**
    $ sudo apt-get install openssh-server
    $ sudo apt-get install net-tools



#### **Pre-Installation Steps On Both Master & Slave (To Install Kubernetes)**

The following steps have to be executed on both the master and node machines. Let’s call the the master as ‘_kmaster_‘ and node as ‘_knode_‘.

First, login as ‘sudo’ user because the following set of commands need to be executed with ‘sudo’ permissions. Then, update your ‘apt-get’ repository.

    $ sudo su
    # swapoff -a
    # nano /etc/fstab
    # exit

Comment out the swap line with "#", then press ‘Ctrl+X’, then press ‘Y’ and then press ‘Enter’ to Save the file.

#### **Update The Hostnames**

Make sure the host name in /etc/hostname is correct

#### **Set static IP for each unit**

Follow the naming convention at the top:

Master: 10.10.0.205
Worker: 10.10.0.20X

Run the following command on both machines to note the IP addresses of each.

     $ ifconfig

 Edit /etc/hosts, add all the nodes, then press ‘Ctrl+X’, then press ‘Y’ and then press ‘Enter’ to Save the file.

After this, restart your machine(s).

### **Install Docker**
    $ sudo apt-get update
    $ sudo apt-get install \
        apt-transport-https \
        ca-certificates \
        curl \
        gnupg-agent \
        software-properties-common
    $ curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
    $ sudo apt-key fingerprint 0EBFCD88
    $ sudo add-apt-repository \
       "deb [arch=amd64] https://download.docker.com/linux/ubuntu \
       $(lsb_release -cs) \
       stable"
    $ apt-cache madison docker-ce #this will give you the version youu want, 18.0.9 probably
    $ sudo apt-get install -y docker-ce=5:18.09.9~3-0~ubuntu-bionic docker-ce-cli=5:18.09.9~3-0~ubuntu-bionic containerd.io #or whatever version depending on OS but going for 18.09
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
    # apt-get update && apt-get install -qy kubelet=1.15.5-00 kubectl=1.15.5-00 kubeadm=1.15.5-00
    # exit

#### **Master Setup**

    $ sudo kubeadm init --apiserver-advertise-address=10.10.0.205 --pod-network-cidr=10.244.0.0/16
    $ mkdir -p $HOME/.kube
    $ sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
    $ sudo chown $(id -u):$(id -g) $HOME/.kube/config
    $ kubectl apply -f https://github.com/coreos/flannel/raw/master/Documentation/kube-flannel.yml
    $ kubectl taint nodes --all node-role.kubernetes.io/master-

#### **Node Setup**

Copy the join command's out put, should look something like this:

    sudo kubeadm join 10.10.0.205:6443 --token randomtoken \
        --discovery-token-ca-cert-hash sha256:randomhash -v=5

Run it on a node to join the node.



#### **To-do / Roadmap**

Kubernetes Cluster Setup + mig
1. Build cluster (10.10.0.205+ for ip range)
    - PKM001L (10.10.0.205)
    - PKW001L (10.10.0.66) - need to set as static
    - PRD002L (10.10.0.200)
    -
    **STATUS**: Semi-Complete

2. Deploy rook-ceph storage
    - cluster
    - filesystem
    - pvc
    - storage-class

    **STATUS**: Complete

3. Setup Ingress so http://subdomain.dcunhahome.com -> Cluster

    **STATUS**: Complete

4. Migrate dockers from PRD001L and mount PRD001L as nfs, use new ceph storage as location for dockers
    - plex      -> UP
    - heimdall  -> replaced with organizr2
    - radarr    -> UP
    - sabnzbd   -> UP
    - delugevpn -> Created not deployed
    - sonarr    -> UP
    - unmanic   -> Waiting for PRD001L

    **STATUS**: In-Progress

5. Possible new pods
    -prometheus
    -searchlight

    **STATUS**: Not Started

6. Migrate data from PRD001L to cluster, keep ndrive on unraid but swap computers

    **STATUS**: Not Started
