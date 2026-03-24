#!/bin/bash
# Script de Bootstrap para novas VMs

USER="ansible"
# CHAVE PÚBLICA:
PUB_KEY="ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQCvyZk1CGIdkI3jY45qr/8nNyRLhh+Tnu+kybU2du9WngA/E1rkbfT0fSF2qL0mKxPUMqdI7PiaLyCvu6EYyQ3TqHuIjmdZXFVlXwImlauY6BM4b2daS8qUd0kuAGQKnx0HCSR3Prsc50eQBB0okGQh/UlqcB/QFpfZhTDuV3Cf2lFLX7rYq/URr/EegVyOU3JE0t1bvR79mw7sCcnfNntZ+6Vnu89mu7mSs2J9Qry4RKXqhlvCxefsBUpGJTw9SlkEVPEt3TGtOkGAkmDBnpzg6c165Rzk6JhvMh1mP9JZbYHfU3lE4bn1elbiqxCLFrRK36d9WFMMFzkLdU09wyS3SJ0TFq+q5n+HN/mv7OHuCARCGRcI2ZMQlyZ73NybIOowUMJK8Y8LEhco81rVk5Jcd6v4db/SugCjhPzweIZwSqaoUUzrw6h+eesTui/yRdoBka2pxAI6KitsEBCCmqKhy/onuQ7/U/iewaOyIRU7Pv5JYW3IgcE5XpPHuI1V9+E43Mrd0KhEogSbh8AHrkk4VSu+EpltWaTLoZ5JHPg1ABk+du05AnAqQUHVOqvqcOCbz7nvgoTsZsgnIMF0jC5ra8AIZ2+2HY4fXtRtbJQUlBBVZUsOL/J+mfhEqxk9hcB5C/jRZzvMcED/FA+JmoayUci9MZzMiBomN8nmKV7YBw== root@awxvm"

# 1. Cria o usuário e limpa vestígios de senha 
useradd $USER 2>/dev/null || echo "Usuário já existe"
echo "$USER:1" | chpasswd

# 2. Configura o Sudoers
echo "$USER ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/$USER
chmod 440 /etc/sudoers.d/$USER

# 3. CRIA A PASTA E A AUTHORIZED_KEYS
mkdir -p /home/$USER/.ssh
echo "$PUB_KEY" > /home/$USER/.ssh/authorized_keys

# 4. PERMISSÕES CRÍTICAS
chown -R $USER:$USER /home/$USER/.ssh
chmod 700 /home/$USER/.ssh
chmod 600 /home/$USER/.ssh/authorized_keys

echo "A chave pública foi autorizada!"

# 5. Update OS
dnf update -y