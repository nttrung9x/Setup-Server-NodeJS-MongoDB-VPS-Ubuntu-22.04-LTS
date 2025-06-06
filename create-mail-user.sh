#!/bin/bash

read -p "Nhập domain chính (ví dụ: trungfox.com): " DOMAIN

# === TẠO USER MAIL no-reply ===
MAIL_USER="no-reply"
MAIL_PASS=$(openssl rand -base64 12)
sudo useradd $MAIL_USER
echo "$MAIL_USER:$MAIL_PASS" | sudo chpasswd
mkdir -p /home/$MAIL_USER/Maildir
chown -R $MAIL_USER:$MAIL_USER /home/$MAIL_USER

systemctl restart opendkim postfix

echo -e "\n📧 SMTP auth dùng gửi mail:"
echo -e "  SMTP server: mail.$DOMAIN"
echo -e "  SMTP port: 587 (STARTTLS)"
echo -e "  Username: $MAIL_USER"
echo -e "  Password: $MAIL_PASS\n"



