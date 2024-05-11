#!/bin/sh
sudo apt-get install neofetch -y

for f in /etc/update-motd.d/*; do mv "$f" "$f.bak"; done
sudo bash -c $'echo "neofetch" >> /etc/profile.d/mymotd.sh && chmod +x /etc/profile.d/mymotd.sh'