#!/bin/bash

sudo dmsetup remove_all && echo  "Removed Ceph dmsetup"
sudo rm -r /ceph && echo "Deleted /ceph"
sudo rm -r /var/lib/rook && echo "Delete /var/lib/rook"
sudo wipefs -a /dev/sdb && echo "Device: /dev/sdb wiped"
sudo wipefs -a /dev/sdc && echo "Device: /dev/sdc wiped"
