#!/bin/bash

sudo dmsetup remove_all && echo  "Removed Ceph dmsetup"
sudo rm -r /ceph && echo "Deleted /ceph"
sudo rm -r /var/lib/rook && echo "Delete /var/lib/rook"
