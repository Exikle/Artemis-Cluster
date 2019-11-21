## Rook Quick

The following are steps to deploy Artemis-Cluster's rook ceph storage


#### Node Preperation

Find out all the drives installed and make sure they're wiped. You must be logged into each node. Can ssh into them nodes.

    $ lsblk
    $ wipsfs -a /dev/sdX

#### Installation Instructions

1. After all drives are wiped then start deploying the rook-ceph cluster

    $ kubectl create -f common.yaml
    $ kubectl create -f operator.yaml
    $ kubectl create -f ceph-cluster.yaml
    $ kubectl create -f toolbox.yaml

2. Wait till all `osd-prepare`pods are in complete state and then start provisioning storage

    $ kubectl create -f filesystem.yaml
    $ kubectl create -f filesystem-pvc.yaml

3. To check status of ceph storage you can do

    $ kubectl get pods -n rook-ceph

    Copy the toolbox deployment name and then run

    $ kubectl exec -it -n rook-ceph 'tool box name' bash
    # [root@MACHINENAME /]# ceph status
    # [root@MACHINENAME /]# ceph osd status
    # [root@MACHINENAME /]# exit
