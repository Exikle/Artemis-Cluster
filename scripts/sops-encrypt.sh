#! /bin/bash
read -p "Please Enter File to Decrypt: " $file
sops --decrypt --age $(cat $SOPS_AGE_KEY_FILE |grep -oP "public key: \K(.*)") --encrypted-regex '^(data|stringData)$' --in-place $file
