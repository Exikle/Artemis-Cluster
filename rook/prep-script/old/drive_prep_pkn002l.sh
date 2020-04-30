#!/bin/bash

sudo dmsetup remove_all && echo  "Removed ceph label from all drives"
sudo rm -r /ceph && echo "Deleted /ceph"
sudo rm -r /var/lib/rook && echo "Deleted /var/lib/rook"
