#! /bin/bash
read -p "Please Enter File to Encrypt: " $file
sops --encrypt --age $(cat $SOPS_AGE_KEY_FILE |grep -oP "public key: \K(.*)") --encrypted-regex '^(data|stringData)$' --in-place $file
