#!/bin/bash

sudo dmsetup remove_all && echo  "Removed Ceph dmsetup"
sudo rm -r /ceph && echo "Deleted /ceph"
sudo rm -r /var/lib/rook && echo "Delete /var/lib/rook"
sudo wipefs -a /dev/sdb && echo "Device: /dev/sdb wiped"
sudo wipefs -a /dev/sdc && echo "Device: /dev/sdc wiped"
sudo wipefs -a /dev/sdd && echo "Device: /dev/sdd wiped"
sudo wipefs -a /dev/sde && echo "Device: /dev/sde wiped"
sudo wipefs -a /dev/sdf && echo "Device: /dev/sdf wiped"
sudo wipefs -a /dev/sdg && echo "Device: /dev/sdg wiped"
sudo wipefs -a /dev/sdh && echo "Device: /dev/sdh wiped"

