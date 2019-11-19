## Rook Quick

Steps to deploy cluster

Do the following on each node:

    $ lsblk
    $ wipsfs -a /dev/sdX

After all drives are wiped then start deploying the rook-ceph cluster

    $ kubectl create -f common.yaml
    $ kubectl create -f operator.yaml
    $ kubectl create -f ceph-cluster.yaml
    $ kubectl create -f toolbox.yaml

Wait till all `osd-prepare`pods are in complete state and then start provisioning storage

    $ kubectl create -f filesystem.yaml
    $ kubectl create -f filesystem-pvc.yaml
