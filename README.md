# ===========================
# VPS Setup Script for Ubuntu 22.04 LTS (Updated: 2025-06-06)
# - Node.js app with Express + Cluster
# - MongoDB database (local usage)
# - NGINX reverse proxy with Let's Encrypt SSL
# - Postfix + OpenDKIM for sending email
# ===========================

# install setup full
```bash
curl -O https://raw.githubusercontent.com/nttrung9x/Setup-Server-NodeJS-MongoDB-VPS-Ubuntu-22.04-LTS/refs/heads/main/setup-vps.sh
chmod +x setup-vps.sh
sudo bash setup-vps.sh
```

# create new user email server
```bash
curl -O https://raw.githubusercontent.com/nttrung9x/Setup-Server-NodeJS-MongoDB-VPS-Ubuntu-22.04-LTS/refs/heads/main/create-mail-user.sh
chmod +x create-mail-user.sh
sudo bash create-mail-user.sh
```
