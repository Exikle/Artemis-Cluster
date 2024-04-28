# Artemis Cluster | Storage

Repo to track my setup and deployment of my K3S Cluster. This is in no ways "ideal" or "production ready" but it works for me 

---

#### Resources
- [1] https://jonathangazeley.com/2021/01/05/using-truenas-to-provide-persistent-storage-for-kubernetes/
- [2] https://github.com/democratic-csi/democratic-csi 


prep each node (not sure if control planes need this but whatever)

sudo apt-get install -y cifs-utils nfs-common open-iscsi lsscsi sg3-utils multipath-tools scsitools

sudo tee /etc/multipath.conf <<-'EOF'
defaults {
    user_friendly_names yes
    find_multipaths yes
}
EOF

sudo systemctl enable multipath-tools.service
sudo service multipath-tools restart
sudo systemctl status multipath-tools

sudo systemctl enable open-iscsi.service
sudo service open-iscsi start
sudo systemctl status open-iscsi

--
helm repo add democratic-csi https://democratic-csi.github.io/charts/
helm repo update

# helm upgrade --install --create-namespace --values iscsi.yaml --namespace democratic-csi iscsi democratic-csi/democratic-csi

helm upgrade \
--install \
--values truenas-iscsi.yaml \
--namespace democratic-csi \
--create-namespace \
zfs-iscsi democratic-csi/democratic-csi
