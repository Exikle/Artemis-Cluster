## Rook Quick

The following are steps to deploy Artemis-Cluster's rook ceph storage


#### Node Preperation

Find out all the drives installed and make sure they're wiped. You must be logged into each node. Can ssh into them nodes.

    $ lsblk
    $ wipsfs -a /dev/sdX.

Run clean-node.sh, for it to be done automatically.

#### Installation Instructions

1. After all drives are wiped then start deploying the rook-ceph cluster


    $ kubectl create -f common.yaml
    $ kubectl create -f operator.yaml
    $ kubectl create -f ceph-cluster.yaml
    $ kubectl create -f toolbox.yaml

2. Wait till all `osd-prepare`pods are in complete state and then start provisioning storage


    $ kubectl create -f artemisfs.yaml
    $ kubectl create -f ssd-block.yaml
    $ kubectl create -f pvc/

3. To check status of ceph storage you can do

    $ kubectl get pods -n rook-ceph

Copy the toolbox deployment name and then run


    $ kubectl -n rook-ceph exec -it $(kubectl -n rook-ceph get pod -l "app=rook-ceph-tools" -o jsonpath='{.items[0].metadata.name}') bash
    $ ceph status
    $ ceph osd status
    $ ceph df
    $ rados df
    $ ceph osd pool get afs-ec-data0 pg_num
    $ ceph osd pool get afs-ec-data0 pgp_num
    $ ceph osd pool set afs-ec-data0 pg_num 1024
    $ ceph osd pool set afs-ec-data0 pgp_num 1024

#### Tips

Restart operator


    kubectl -n rook-ceph delete pod -l app=rook-ceph-operator
