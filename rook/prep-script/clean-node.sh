#!/bin/bash

CEPHDIR="/ceph"
ROOKDIR="/var/lib/rook"
NODENAME=$(hostname)

PKN001L_BOOT_UUID="fcaed976-5723-46d1-a894-9a96f480156a"
PKN002L_BOOT_UUID="c49c0ffb-bb6d-4165-828e-829d005eb0b3"
PKN003L_BOOT_UUID="56518c1d-ca00-4ade-aaf4-8dbfb98ce8e5"
PKN004L_BOOT_UUID="4a7027ca-7722-4f0e-8e93-4b637b07c2ac"
PKN005L_BOOT_UUID="9a3995f8-ce5d-4ec0-ade8-6edbf5aa9a99"

echo [TASK] Preparing drives for ROOK/CEPH usage on kubernetes node ${NODENAME^^}

echo [TASK] Removing all device-mapper drivers
sudo dmsetup remove_all && echo  "  Removed CEPH device-mapper on drives (using dmsetup)"

echo [TASK] Removing /ceph directory
if [ -d "$CEPHDIR" ]; then
  sudo rm -r /ceph && echo "  Deleted /ceph"
else
  echo "  /ceph doesn't exist, skipping"
fi

echo [TASK] Removing /var/lib/rook directory
if [ -d "$ROOKDIR" ]; then
  sudo rm -r /var/lib/rook && echo "  Deleted /var/lib/rook"
else
  echo "  /var/lib/rook doesn't exist, skipping"
fi

echo [TASK] Wiping disks
DRIVES=( $(ls /dev/ | grep sd | sed -nr '/^.{3}$/p') )

for i in "${DRIVES[@]}"
do
    if sudo blkid /dev/$i | grep -q $PKN001L_BOOT_UUID; then
       echo "  /dev/$i is the boot disk, skipping"
    elif sudo blkid /dev/$i | grep -q $PKN002L_BOOT_UUID; then
       echo "  /dev/$i is the boot disk, skipping"
    elif sudo blkid /dev/$i | grep -q $PKN003L_BOOT_UUID; then
       echo "  /dev/$i is the boot disk, skipping"
    elif sudo blkid /dev/$i | grep -q $PKN004L_BOOT_UUID; then
       echo "  /dev/$i is the boot disk, skipping"
    elif sudo blkid /dev/$i | grep -q $PKN005L_BOOT_UUID; then
       echo "  /dev/$i is the boot disk, skipping"
    else
      sudo wipefs -a "/dev/$i" && echo "  /dev/$i wiped"
    fi
done

echo [TASK] ${NODENAME^^} is ready for ROOK/CEPH on Kubernetes
