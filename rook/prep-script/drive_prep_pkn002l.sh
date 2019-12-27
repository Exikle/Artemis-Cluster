#!/bin/bash

sudo dmsetup remove_all && echo  "Removed ceph label from all drives"
sudo rm -r /ceph && echo "Deleted /ceph"
sudo rm -r /var/lib/rook && echo "Deleted /var/lib/rook"
sudo wipefs -a /dev/sdb && echo "Device: /dev/sdb wiped"
sudo wipefs -a /dev/sdc && echo "Device: /dev/sdc wiped"
sudo wipefs -a /dev/sdd && echo "Device: /dev/sdd wiped"
