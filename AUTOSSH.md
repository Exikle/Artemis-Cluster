http://www.linuxproblem.org/art_9.html

Allow personal workstation to ssh without password.

Can do all this from personal workstation

cd ~
ssh-keygen -t rsa 
ssh exikle@node mkdir -p .ssh
cat ~/.ssh/id_rsa.pub | ssh exikle@node 'cat >> .ssh/authorized_keys'
