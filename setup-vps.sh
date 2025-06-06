#!/bin/bash

echo -e "\e[34m==== VPS Auto Setup - Ubuntu 22.04 LTS ====\e[0m"

# ================== INPUT =====================
read -p "Nhập domain chính (ví dụ: trungfox.com): " DOMAIN
read -p "Nhập port Node.js app (ví dụ: 3000): " NODE_PORT
read -p "Nhập đường dẫn my-app (ví dụ: /var/www/nodejs/my-app): " APP_PATH
read -p "Nhập tên file main js (ví dụ: server.js): " MAIN_JS
read -p "Chọn phiên bản Node.js (ví dụ: 20): " NODE_VERSION
read -p "Chọn phiên bản MongoDB (ví dụ: 7.0): " MONGO_VERSION
read -p "Chọn phiên bản Nginx (nhấn Enter để dùng mặc định): " NGINX_VERSION

MAIL_DOMAIN="mail.${DOMAIN}"

# ================== FIREWALL ==================
echo -e "\n🛡️  Kiểm tra và tắt firewall..."
sudo ufw disable 2>/dev/null || true
sudo systemctl stop firewalld 2>/dev/null || true
sudo systemctl disable firewalld 2>/dev/null || true

# ============= TẠO APP DIR + SHORTCUT ==========
if [ ! -d "$APP_PATH" ]; then
    echo "📁 Tạo thư mục: $APP_PATH"
    sudo mkdir -p "$APP_PATH"
    sudo chown -R $USER:$USER "$APP_PATH"
fi

CURDIR=$(pwd)
APP_NAME=$(basename "$APP_PATH")
ln -sfn "$APP_PATH" "$CURDIR/$APP_NAME"
echo "🔗 Shortcut tạo tại: $CURDIR/$APP_NAME → $APP_PATH"

# ================= NODEJS ======================
echo -e "\n⬇️  Cài Node.js $NODE_VERSION..."
curl -fsSL https://deb.nodesource.com/setup_"$NODE_VERSION".x | sudo -E bash -
sudo apt install -y nodejs
node -v && npm -v

# ================= MONGODB =====================
echo -e "\n⬇️  Cài MongoDB $MONGO_VERSION..."
wget -qO - https://www.mongodb.org/static/pgp/server-"$MONGO_VERSION".asc | sudo apt-key add -
echo "deb [ arch=amd64,arm64 ] https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/$MONGO_VERSION multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-org.list
sudo apt update
sudo apt install -y mongodb-org
sudo systemctl enable mongod --now

# ================= NGINX =======================
echo -e "\n⬇️  Cài Nginx..."
sudo apt install -y nginx
sudo systemctl enable nginx --now

# ============ NGINX CONFIG ====================
cat <<EOF | sudo tee /etc/nginx/sites-available/$DOMAIN
server {
    listen 80;
    server_name $DOMAIN;

    location / {
        proxy_pass http://localhost:$NODE_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
    }
}
EOF

sudo ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx

# ================= SSL ========================
echo -e "\n🔒 Cài SSL Let's Encrypt..."
sudo apt install -y certbot python3-certbot-nginx
sudo certbot --nginx -d $DOMAIN -d $MAIL_DOMAIN --non-interactive --agree-tos -m admin@$DOMAIN

# Tự động gia hạn
(crontab -l ; echo "0 3 * * * /usr/bin/certbot renew --quiet") | crontab -

# ============= SYSTEMD SERVICE ================
echo -e "\n⚙️ Tạo systemd service..."
cat <<EOF | sudo tee /etc/systemd/system/myapp.service
[Unit]
Description=Node.js My App
After=network.target

[Service]
ExecStart=/usr/bin/node $APP_PATH/$MAIN_JS
WorkingDirectory=$APP_PATH
Restart=always
User=$USER
Environment=PORT=$NODE_PORT

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl enable myapp
sudo systemctl restart myapp

# ============ MAIL SERVER =====================
echo -e "\n📧 Cài Postfix + Dovecot..."
sudo apt install -y postfix dovecot-core dovecot-imapd mailutils libsasl2-modules

# Cấu hình postfix cơ bản
sudo postconf -e "home_mailbox= Maildir/"
sudo postconf -e "smtpd_tls_cert_file=/etc/letsencrypt/live/$MAIL_DOMAIN/fullchain.pem"
sudo postconf -e "smtpd_tls_key_file=/etc/letsencrypt/live/$MAIL_DOMAIN/privkey.pem"
sudo postconf -e "smtpd_use_tls=yes"
sudo postconf -e "smtpd_sasl_type=dovecot"
sudo postconf -e "smtpd_sasl_path=private/auth"
sudo postconf -e "smtpd_sasl_auth_enable=yes"
sudo postconf -e "smtpd_recipient_restrictions=permit_sasl_authenticated,permit_mynetworks,reject_unauth_destination"

# Cấu hình dovecot auth
sudo tee /etc/dovecot/conf.d/10-auth.conf > /dev/null <<EOF
disable_plaintext_auth = yes
auth_mechanisms = plain login
!include auth-system.conf.ext
EOF

sudo tee /etc/dovecot/conf.d/10-master.conf > /dev/null <<EOF
service auth {
  unix_listener /var/spool/postfix/private/auth {
    mode = 0660
    user = postfix
    group = postfix
  }
}
EOF

sudo systemctl restart postfix dovecot

# === TẠO USER MAIL no-reply ===
MAIL_USER="no-reply"
MAIL_PASS=$(openssl rand -base64 12)
sudo useradd $MAIL_USER
echo "$MAIL_USER:$MAIL_PASS" | sudo chpasswd
mkdir -p /home/$MAIL_USER/Maildir
chown -R $MAIL_USER:$MAIL_USER /home/$MAIL_USER

# ============== THÔNG TIN CUỐI ===============
echo -e "\n🎉 \e[32mHoàn tất cài đặt lúc $(date '+%Y-%m-%d %H:%M')\e[0m"

echo -e "\n📌 Trỏ các DNS như sau:"
echo -e "A    @               → VPS_IP"
echo -e "A    mail            → VPS_IP"
echo -e "MX   @               → mail.$DOMAIN (Priority 10)"
echo -e "TXT  @               → v=spf1 a mx ip4:VPS_IP ~all"
echo -e "TXT  mail._domainkey → DKIM nếu cài thêm (optional)"
echo -e "TXT  _dmarc          → v=DMARC1; p=none; rua=mailto:admin@$DOMAIN"

echo -e "\n📧 SMTP auth dùng gửi mail:"
echo -e "  SMTP server: mail.$DOMAIN"
echo -e "  SMTP port: 587 (STARTTLS)"
echo -e "  Username: $MAIL_USER"
echo -e "  Password: $MAIL_PASS\n"

echo -e "🔗 Shortcut: cd $CURDIR/$APP_NAME → truy cập nhanh my-app"
