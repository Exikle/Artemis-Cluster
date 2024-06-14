# K3S Node Prep

Create cloudinit for repeatable + consistent nodes.

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
````

Configure 5 new nodes

````
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

###### NOTE

On one of the nodes there was issues pinging so ran the following:

````bash
cd /var/lib/dpkg/info/ && sudo apt install --reinstall $(grep -l 'setcap' * | sed -e 's/\.[^.]*$//g' | sort --unique)
````
