#!/bin/bash

# ===========================
# VPS Setup Script for Ubuntu 22.04 LTS (Updated: 2025-06-06)
# - Node.js app with Express + Cluster
# - MongoDB database (local usage)
# - NGINX reverse proxy with Let's Encrypt SSL
# - Postfix + OpenDKIM for sending email
# ===========================

set -e

# Hiển thị thông tin
echo "======================================================="
echo "🚀 VPS SETUP SCRIPT - Phiên bản 2.0"
echo "🗓️ Ngày cập nhật: 2025-06-06 07:24:37"
echo "👤 Người thực hiện: nttrung9x"
echo "======================================================="

# Kiểm tra quyền root
if [ "$EUID" -ne 0 ]; then
  echo "⚠️ Vui lòng chạy script này với quyền root (sudo)."
  exit 1
fi

# Kiểm tra người dùng
CURRENT_USER=$(whoami)
echo "👤 Người dùng hiện tại: $CURRENT_USER"

get_user_inputs() {
  # Lấy thông tin từ người dùng
  read -p "Nhập domain chính (ví dụ: trungfox.com): " DOMAIN
  read -p "Nhập tên file chính của app Node.js (ví dụ: server.js): " MAIN_JS
  read -p "Nhập port Node.js app (ví dụ: 3000): " APP_PORT
  
  # Tự động tạo APP_PATH từ domain
  APP_PATH="/var/www/nodejs/$(echo $DOMAIN | tr '.' '_')"
  
  MAIL_DOMAIN="mail.${DOMAIN}"
  
  # Tùy chọn phiên bản Node.js
  echo -e "\nChọn phiên bản Node.js:"
  echo "1) 16.x"
  echo "2) 18.x"
  echo "3) 20.x"
  echo "4) 21.x"
  echo "5) 22.x"
  echo "0) Nhập phiên bản khác"
  read -p "Chọn số (1-5, hoặc 0 để nhập tùy chỉnh): " node_choice

  case $node_choice in
      1) NODE_VER="16.x" ;;
      2) NODE_VER="18.x" ;;
      3) NODE_VER="20.x" ;;
      4) NODE_VER="21.x" ;;
      5) NODE_VER="22.x" ;;
      0) 
          read -p "Nhập phiên bản Node.js (ví dụ: 20): " CUSTOM_NODE_VER
          NODE_VER="${CUSTOM_NODE_VER}.x"
          ;;
      *) 
          echo "Lựa chọn không hợp lệ, sử dụng mặc định 20.x"
          NODE_VER="20.x"
          ;;
  esac
  
  # Tùy chọn phiên bản MongoDB
  echo -e "\nChọn phiên bản MongoDB:"
  echo "1) 5.0"
  echo "2) 6.0"
  echo "3) 7.0"
  echo "4) 7.1"
  echo "0) Nhập phiên bản khác"
  read -p "Chọn số (1-4, hoặc 0 để nhập tùy chỉnh): " mongo_choice

  case $mongo_choice in
      1) MONGO_VER="5.0" ;;
      2) MONGO_VER="6.0" ;;
      3) MONGO_VER="7.0" ;;
      4) MONGO_VER="7.1" ;;
      0) 
          read -p "Nhập phiên bản MongoDB (ví dụ: 7.0): " MONGO_VER
          ;;
      *) 
          echo "Lựa chọn không hợp lệ, sử dụng mặc định 7.0"
          MONGO_VER="7.0"
          ;;
  esac
  
  # Tùy chọn phiên bản NGINX
  echo -e "\nChọn phiên bản NGINX:"
  echo "1) stable"
  echo "2) mainline"
  read -p "Chọn số (1-2): " nginx_choice

  case $nginx_choice in
      1) NGINX_VER="stable" ;;
      2) NGINX_VER="mainline" ;;
      *) 
          echo "Lựa chọn không hợp lệ, sử dụng mặc định stable"
          NGINX_VER="stable"
          ;;
  esac

  # Hiển thị thông tin để xác nhận
  echo -e "\n📋 Thông tin cài đặt:"
  echo "- Domain chính: ${DOMAIN}"
  echo "- Mail domain: ${MAIL_DOMAIN}"
  echo "- Đường dẫn ứng dụng: ${APP_PATH}"
  echo "- File main JS: ${MAIN_JS}"
  echo "- Port: ${APP_PORT}"
  echo "- Node.js: ${NODE_VER}"
  echo "- MongoDB: ${MONGO_VER}"
  echo "- NGINX: ${NGINX_VER}"
  
  read -p "Thông tin đã chính xác? (y/n): " confirm
  if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "Vui lòng nhập lại thông tin."
    get_user_inputs
  fi
}

# Lấy thông tin cài đặt từ người dùng
get_user_inputs

LOG_FILE="/var/log/vps_setup_$(date -u '+%Y%m%d%H%M%S').log"

# Xác định tên thư mục cuối cùng từ đường dẫn để làm shortcut
APP_DIR_NAME=$(basename "$APP_PATH")

# Ghi log
exec > >(tee -a "$LOG_FILE") 2>&1
echo "📋 Log file: $LOG_FILE"

echo "🚀 Bắt đầu cài đặt với các thông số đã xác nhận: $(date -u '+%Y-%m-%d %H:%M:%S')"

# Tạo thư mục nếu chưa có
mkdir -p "$APP_PATH"
mkdir -p "$APP_PATH/logs"
mkdir -p "$APP_PATH/uploads"
mkdir -p "$APP_PATH/public"

# Tạo shortcut tại thư mục hiện tại theo tên thư mục cuối cùng
if [ ! -L "./$APP_DIR_NAME" ] && [ ! -e "./$APP_DIR_NAME" ]; then
  ln -s "$APP_PATH" ./$APP_DIR_NAME
  echo "🔗 Đã tạo shortcut ./$APP_DIR_NAME -> $APP_PATH"
fi

# Tắt firewall nếu có
if command -v ufw >/dev/null 2>&1; then
  echo "Tắt UFW nếu đang bật..."
  ufw disable || true
fi

# Cập nhật hệ thống
echo "📦 Cập nhật hệ thống..."
apt update && apt upgrade -y

# Cài đặt các gói cần thiết
echo "🛠️ Cài đặt các gói cơ bản..."
apt install -y apt-transport-https ca-certificates gnupg curl wget git htop vim net-tools zip unzip mlocate build-essential

# Node.js - Kiểm tra và sử dụng phương pháp cài đặt hiện tại
echo "🟢 Đang cài đặt Node.js phiên bản ${NODE_VER}..."
curl -fsSL https://deb.nodesource.com/setup_${NODE_VER} | bash -
if [ $? -ne 0 ]; then
  echo "Sử dụng phương pháp cài đặt thay thế cho Node.js..."
  # Phương pháp thay thế nếu repository NodeSource thay đổi
  NODE_MAJOR=$(echo $NODE_VER | cut -d. -f1)
  curl -fsSL https://nodejs.org/dist/latest-v${NODE_MAJOR}/setup-v${NODE_MAJOR}.x | bash -
fi
apt install -y nodejs
npm install -g pm2 yarn

echo "Node.js đã được cài đặt:"
node -v
npm -v
echo "PM2 đã được cài đặt:"
pm2 --version

# MongoDB - Kiểm tra và sử dụng URL hiện tại
echo "🗄️ Đang cài đặt MongoDB phiên bản ${MONGO_VER}..."
wget -qO - https://www.mongodb.org/static/pgp/server-${MONGO_VER}.asc | gpg --dearmor -o /usr/share/keyrings/mongodb-server-${MONGO_VER}.gpg
if [ $? -ne 0 ]; then
  echo "Không thể tải khóa MongoDB. Thử lại với URL thay thế..."
  wget -qO - https://pgp.mongodb.com/server-${MONGO_VER}.asc | gpg --dearmor -o /usr/share/keyrings/mongodb-server-${MONGO_VER}.gpg
fi

# Thêm repository MongoDB và cài đặt
ubuntu_codename=$(lsb_release -cs)
echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-${MONGO_VER}.gpg ] https://repo.mongodb.org/apt/ubuntu ${ubuntu_codename}/mongodb-org/${MONGO_VER} multiverse" | tee /etc/apt/sources.list.d/mongodb-org-${MONGO_VER}.list

apt update || {
  echo "Không thể cập nhật từ repository MongoDB. Thử với cấu hình thay thế..."
  # Thử với repository thay thế
  if [ "$ubuntu_codename" = "jammy" ]; then
    repository_codename="jammy"
  else
    repository_codename=$(lsb_release -cs)
  fi
  echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-${MONGO_VER}.gpg ] https://repo.mongodb.org/apt/ubuntu ${repository_codename}/mongodb-org/${MONGO_VER} multiverse" | tee /etc/apt/sources.list.d/mongodb-org-${MONGO_VER}.list
  apt update
}

apt install -y mongodb-org

# Cấu hình MongoDB - chỉ cho phép sử dụng local port 27017
echo "Cấu hình MongoDB cho sử dụng cục bộ trên port 27017..."
# Sửa file cấu hình để chỉ bind vào localhost
sed -i 's/bindIp: 127.0.0.1/bindIp: 127.0.0.1/' /etc/mongod.conf
# Đảm bảo MongoDB chỉ lắng nghe từ localhost
grep -q "bindIp: 127.0.0.1" /etc/mongod.conf || echo "  bindIp: 127.0.0.1" >> /etc/mongod.conf
# Đảm bảo port 27017
grep -q "port: 27017" /etc/mongod.conf || sed -i '/^  port:/c\  port: 27017' /etc/mongod.conf

systemctl enable mongod
systemctl restart mongod

echo "MongoDB đã được cài đặt và cấu hình cho sử dụng cục bộ:"
mongod --version | head -n 1

# NGINX - Kiểm tra và sử dụng URL hiện tại
echo "🌐 Đang cài đặt NGINX phiên bản ${NGINX_VER}..."
apt install -y curl gnupg2 ca-certificates lsb-release ubuntu-keyring

# Tải khóa NGINX 
curl https://nginx.org/keys/nginx_signing.key | gpg --dearmor | tee /usr/share/keyrings/nginx-archive-keyring.gpg > /dev/null
if [ $? -ne 0 ]; then
  echo "Không thể tải khóa NGINX. Thử lại với URL thay thế..."
  curl https://packages.nginx.org/keys/nginx_signing.key | gpg --dearmor | tee /usr/share/keyrings/nginx-archive-keyring.gpg > /dev/null
fi

# Thêm repository NGINX
echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/${NGINX_VER}/ubuntu ${ubuntu_codename} nginx" | tee /etc/apt/sources.list.d/nginx.list

apt update || {
  echo "Không thể cập nhật từ repository NGINX. Thử với repository mặc định của Ubuntu..."
  # Sử dụng repository của Ubuntu nếu repository chính thức không khả dụng
  rm /etc/apt/sources.list.d/nginx.list
  apt update
}

# Cài đặt NGINX
apt install -y nginx
echo "NGINX đã được cài đặt:"
nginx -v

# Backup tệp cấu hình NGINX gốc
if [ -f /etc/nginx/nginx.conf ]; then
  cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.backup.$(date +%Y%m%d%H%M%S)
fi

# Tạo thư mục sites-available và sites-enabled nếu không tồn tại
mkdir -p /etc/nginx/sites-available
mkdir -p /etc/nginx/sites-enabled

# Chỉnh sửa cấu hình NGINX để bao gồm sites-enabled và tối ưu hiệu suất
cat > /etc/nginx/nginx.conf <<EOF
user nginx;
worker_processes auto;
pid /var/run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

# Tăng số lượng worker connections cho hiệu suất cao
events {
    worker_connections 4096;
    multi_accept on;
    use epoll;
}

http {
    # Cấu hình cơ bản
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    server_tokens off;

    # Tối ưu hóa buffer
    client_body_buffer_size 10K;
    client_header_buffer_size 1k;
    client_max_body_size 20m;
    large_client_header_buffers 4 4k;

    # Timeout configurations
    client_body_timeout 12;
    client_header_timeout 12;
    send_timeout 10;

    # Bật gzip
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_buffers 16 8k;
    gzip_http_version 1.1;
    gzip_min_length 256;
    gzip_types 
        application/atom+xml
        application/javascript
        application/json
        application/ld+json
        application/manifest+json
        application/rss+xml
        application/vnd.geo+json
        application/vnd.ms-fontobject
        application/x-font-ttf
        application/x-web-app-manifest+json
        application/xhtml+xml
        application/xml
        font/opentype
        image/bmp
        image/svg+xml
        image/x-icon
        text/cache-manifest
        text/css
        text/plain
        text/vcard
        text/vnd.rim.location.xloc
        text/vtt
        text/x-component
        text/x-cross-domain-policy;

    # Bảo mật
    add_header X-Frame-Options SAMEORIGIN;
    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";
    add_header Referrer-Policy strict-origin-when-cross-origin;

    # Thông số TLS
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384';
    ssl_session_tickets off;
    
    # Cấu hình logging
    log_format main '\$remote_addr - \$remote_user [\$time_local] "\$request" '
                    '\$status \$body_bytes_sent "\$http_referer" '
                    '"\$http_user_agent" "\$http_x_forwarded_for" '
                    '\$request_time \$upstream_response_time';
    
    log_format detailed '\$remote_addr - \$remote_user [\$time_local] '
                    '"\$request" \$status \$body_bytes_sent '
                    '"\$http_referer" "\$http_user_agent" '
                    '"\$http_x_forwarded_for" rt=\$request_time uct="\$upstream_connect_time" '
                    'uht="\$upstream_header_time" urt="\$upstream_response_time"';
    
    access_log /var/log/nginx/access.log main;
    error_log /var/log/nginx/error.log warn;

    # Bật file watcher để tự động phát hiện thay đổi cấu hình
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    # Bao gồm các cấu hình khác
    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
EOF

# Certbot - Kiểm tra và cài đặt
echo "🔒 Đang cài đặt Certbot..."
apt install -y snapd
snap install core
snap refresh core
snap install --classic certbot
ln -sf /snap/bin/certbot /usr/bin/certbot

# Cấu hình NGINX HTTP
cat > /etc/nginx/sites-available/${DOMAIN}.conf <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN} ${MAIL_DOMAIN};
    
    # Ghi log chi tiết để giúp gỡ lỗi
    access_log /var/log/nginx/${DOMAIN}.access.log detailed;
    error_log /var/log/nginx/${DOMAIN}.error.log;

    # Chuyển hướng HTTP sang HTTPS
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF

# Tạo symlink để kích hoạt cấu hình
ln -sf /etc/nginx/sites-available/${DOMAIN}.conf /etc/nginx/sites-enabled/

mkdir -p /var/www/certbot
nginx -t && systemctl reload nginx

# Lấy SSL từ Let's Encrypt
echo "Đang lấy chứng chỉ SSL từ Let's Encrypt..."
certbot certonly --webroot -w /var/www/certbot -d ${DOMAIN} -d ${MAIL_DOMAIN} --agree-tos --register-unsafely-without-email --non-interactive || {
  echo "Không thể lấy chứng chỉ SSL tự động. Thử với phương pháp standalone..."
  systemctl stop nginx
  certbot certonly --standalone -d ${DOMAIN} -d ${MAIL_DOMAIN} --agree-tos --register-unsafely-without-email --non-interactive
  systemctl start nginx
}

# Cấu hình HTTPS với bảo vệ IP thật
cat > /etc/nginx/sites-available/${DOMAIN}-ssl.conf <<EOF
# File cấu hình NGINX cho ${DOMAIN} (Cập nhật: $(date -u '+%Y-%m-%d'))
# Thiết lập bởi nttrung9x

map \$http_x_forwarded_for \$forwarded_for {
    default '';
}

map \$http_x_real_ip \$real_ip {
    default '';
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${DOMAIN};
    
    # Ghi log chi tiết cho việc gỡ lỗi
    access_log /var/log/nginx/${DOMAIN}.ssl-access.log detailed;
    error_log /var/log/nginx/${DOMAIN}.ssl-error.log;

    # Cấu hình SSL
    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_trusted_certificate /etc/letsencrypt/live/${DOMAIN}/chain.pem;
    ssl_dhparam /etc/nginx/ssl/dhparam.pem;

    # Các tham số bảo mật SSL
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;
    ssl_stapling on;
    ssl_stapling_verify on;
    resolver 8.8.8.8 8.8.4.4 valid=300s;
    resolver_timeout 5s;
    
    # Thiết lập HSTS
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;

    # Bảo mật bổ sung
    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options DENY always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy strict-origin-when-cross-origin always;
    add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; font-src 'self'; connect-src 'self';" always;
    add_header Permissions-Policy "geolocation=(), microphone=(), camera=()";
    
    # Giới hạn kích thước body
    client_max_body_size 10M;

    # Bảo vệ một số tệp nhạy cảm
    location ~ /\.(?!well-known) {
        deny all;
    }
    
    # Đường dẫn tĩnh - phục vụ trực tiếp không qua Node.js
    location ~* \.(jpg|jpeg|png|gif|ico|css|js|svg|woff|woff2|ttf|eot)$ {
        root ${APP_PATH}/public;
        expires 30d;
        add_header Cache-Control "public, no-transform";
        try_files \$uri \$uri/ @proxy;
    }
    
    # Tất cả request khác chuyển đến Node.js
    location / {
        # Xóa các header có thể bị giả mạo
        proxy_set_header X-Forwarded-For \$forwarded_for;
        proxy_set_header X-Real-IP \$real_ip;
        
        # Thiết lập lại các header với giá trị đáng tin cậy
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        # Các cấu hình proxy khác
        proxy_pass http://localhost:${APP_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
        proxy_buffering off;
        proxy_read_timeout 120s;
        proxy_connect_timeout 10s;
        proxy_send_timeout 120s;
        
        # Rate limiting cơ bản để tránh tấn công
        limit_req zone=one burst=10 nodelay;
        limit_conn addr 10;
    }
    
    # Fallback cho static files
    location @proxy {
        proxy_pass http://localhost:${APP_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$remote_addr;
    }
}

# Rate limiting zones
limit_req_zone \$binary_remote_addr zone=one:10m rate=1r/s;
limit_conn_zone \$binary_remote_addr zone=addr:10m;

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${MAIL_DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_trusted_certificate /etc/letsencrypt/live/${DOMAIN}/chain.pem;
    
    # Cấu hình bảo mật SSL tương tự
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;
    
    # Trang chào mail server
    location / {
        return 200 "Mail server for ${DOMAIN}";
    }
}
EOF

# Tạo thư mục ssl và dhparam
mkdir -p /etc/nginx/ssl
openssl dhparam -out /etc/nginx/ssl/dhparam.pem 2048

# Tạo symlink để kích hoạt cấu hình HTTPS
ln -sf /etc/nginx/sites-available/${DOMAIN}-ssl.conf /etc/nginx/sites-enabled/

systemctl restart nginx

# Auto renew SSL với Let's Encrypt
echo "Cấu hình tự động gia hạn SSL từ Let's Encrypt..."
(crontab -l 2>/dev/null || echo "") | grep -v "certbot renew" | { cat; echo "0 0 * * * certbot renew --quiet --post-hook 'systemctl reload nginx'"; } | crontab -

# Postfix + OpenDKIM
echo "📧 Đang cài đặt Postfix và OpenDKIM..."
DEBIAN_FRONTEND=noninteractive apt install -y postfix opendkim opendkim-tools
mkdir -p /etc/opendkim/keys/${DOMAIN}
cd /etc/opendkim/keys/${DOMAIN}
opendkim-genkey -s mail -d ${DOMAIN}
chown opendkim:opendkim mail.private

cat > /etc/opendkim/KeyTable <<EOF
mail._domainkey.${DOMAIN} ${DOMAIN}:mail:/etc/opendkim/keys/${DOMAIN}/mail.private
EOF

cat > /etc/opendkim/SigningTable <<EOF
*@${DOMAIN} mail._domainkey.${DOMAIN}
EOF

cat > /etc/opendkim/TrustedHosts <<EOF
127.0.0.1
localhost
${DOMAIN}
EOF

sed -i '/^Socket/c\\Socket inet:12301@localhost' /etc/opendkim.conf
echo "SOCKET=\"inet:12301@localhost\"" >> /etc/default/opendkim

postconf -e "milter_default_action = accept"
postconf -e "milter_protocol = 2"
postconf -e "smtpd_milters = inet:localhost:12301"
postconf -e "non_smtpd_milters = inet:localhost:12301"
postconf -e "myhostname = ${MAIL_DOMAIN}"
postconf -e "mydomain = ${DOMAIN}"
postconf -e "myorigin = ${DOMAIN}"

systemctl restart opendkim postfix

# Kiểm tra tổng lượng RAM và CPU của hệ thống
TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_RAM_MB=$((TOTAL_RAM_KB / 1024))
TOTAL_RAM_GB=$(awk "BEGIN {printf \"%.1f\", ${TOTAL_RAM_MB}/1024}")
CPU_CORES=$(grep -c ^processor /proc/cpuinfo)

# Sử dụng max CPU cores cho cluster, chỉ tính toán RAM
PM2_INSTANCES="max"

# Tính toán max_memory_restart dựa trên RAM và số cores
if [ ${TOTAL_RAM_MB} -lt 1024 ]; then
  # Nếu dưới 1GB RAM
  MAX_MEMORY="$((TOTAL_RAM_MB / (CPU_CORES + 1) / 2))M"
elif [ ${TOTAL_RAM_MB} -lt 2048 ]; then
  # Nếu từ 1-2GB RAM
  MAX_MEMORY="$((TOTAL_RAM_MB / (CPU_CORES + 1) / 2))M"
elif [ ${TOTAL_RAM_MB} -lt 4096 ]; then
  # Nếu từ 2-4GB RAM
  MAX_MEMORY="$((TOTAL_RAM_MB / (CPU_CORES + 1) / 2))M"
elif [ ${TOTAL_RAM_MB} -lt 8192 ]; then
  # Nếu từ 4-8GB RAM
  MAX_MEMORY="$((TOTAL_RAM_MB / CPU_CORES / 2))M"
else
  # Nếu trên 8GB RAM
  MAX_MEMORY="$((TOTAL_RAM_MB / CPU_CORES / 3))M"
fi

echo "🖥️ Thông tin hệ thống:"
echo "   - RAM: ${TOTAL_RAM_GB}GB"
echo "   - CPU: ${CPU_CORES} cores"
echo "   - PM2 instances: ${PM2_INSTANCES} (sử dụng tất cả CPU cores)"
echo "   - PM2 max_memory_restart: ${MAX_MEMORY}"

# Tạo file quy trình pm2 cho Express.js với cluster
echo "Tạo file cấu hình PM2 cho ứng dụng Node.js..."
cat > ${APP_PATH}/ecosystem.config.js <<EOF
module.exports = {
  apps: [{
    name: '${APP_DIR_NAME}',
    script: '${MAIN_JS}',
    instances: "${PM2_INSTANCES}",
    exec_mode: 'cluster',
    autorestart: true,
    watch: false,
    max_memory_restart: '${MAX_MEMORY}',
    env: {
      NODE_ENV: 'production',
      PORT: ${APP_PORT}
    },
    error_file: 'logs/err.log',
    out_file: 'logs/out.log',
    log_file: 'logs/combined.log',
    time: true
  }]
};
EOF

# Tạo file starter.js mẫu nếu app trống
if [ ! -f "${APP_PATH}/${MAIN_JS}" ]; then
  echo "Tạo file Node.js mẫu..."
  cat > ${APP_PATH}/${MAIN_JS} <<EOF
const express = require('express');
const cluster = require('cluster');
const numCPUs = require('os').cpus().length;
const app = express();
const PORT = process.env.PORT || ${APP_PORT};

// Cấu hình Express tin tưởng proxy
app.set('trust proxy', 'loopback');

// Middleware để lấy IP thực của client
app.use((req, res, next) => {
  // Lấy IP của client một cách an toàn
  const clientIp = req.ip || req.headers['x-real-ip'] || req.connection.remoteAddress || 'unknown';
  console.log(\`Request từ IP: \${clientIp}\`);
  req.clientIp = clientIp;
  next();
});

// Route mẫu
app.get('/', (req, res) => {
  res.send(\`Hello from Node.js! Your IP: \${req.clientIp}\`);
});

// Xử lý cluster
if (cluster.isMaster) {
  console.log(\`Master \${process.pid} đang chạy\`);
  
  // Fork workers - Sử dụng tất cả CPU cores
  for (let i = 0; i < numCPUs; i++) {
    cluster.fork();
  }
  
  cluster.on('exit', (worker, code, signal) => {
    console.log(\`Worker \${worker.process.pid} đã thoát\`);
    cluster.fork(); // Thay thế worker đã thoát
  });
} else {
  // Worker chia sẻ TCP connection
  app.listen(PORT, () => {
    console.log(\`Worker \${process.pid} đang lắng nghe trên cổng \${PORT}\`);
  });
}
EOF
fi

# Tạo package.json mẫu nếu chưa có
if [ ! -f "${APP_PATH}/package.json" ]; then
  echo "Tạo file package.json mẫu..."
  cat > ${APP_PATH}/package.json <<EOF
{
  "name": "${APP_DIR_NAME}",
  "version": "1.0.0",
  "description": "Node.js application with Express and Cluster",
  "main": "${MAIN_JS}",
  "scripts": {
    "start": "node ${MAIN_JS}",
    "dev": "nodemon ${MAIN_JS}",
    "pm2": "pm2 start ecosystem.config.js"
  },
  "dependencies": {
    "express": "^4.18.2"
  },
  "devDependencies": {
    "nodemon": "^3.0.1"
  }
}
EOF
fi

# Cài đặt phụ thuộc cho ứng dụng
echo "Cài đặt các gói phụ thuộc Node.js..."
cd ${APP_PATH} && npm install

# Service PM2 app
echo "Đang cấu hình PM2 để khởi động cùng hệ thống..."
pm2 startup
cd ${APP_PATH} && pm2 start ecosystem.config.js
pm2 save

# Cài đặt một số công cụ hữu ích
echo "Đang cài đặt các công cụ bổ sung..."
apt install -y fail2ban logwatch ntp

# Cấu hình Fail2ban
cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 86400
findtime = 3600
maxretry = 5

[sshd]
enabled = true

[nginx-http-auth]
enabled = true

[nginx-botsearch]
enabled = true

[nginx-badbots]
enabled = true
EOF

systemctl restart fail2ban

# Cấu hình giờ hệ thống
timedatectl set-timezone Asia/Ho_Chi_Minh
systemctl restart ntp

# Cấu hình SSH để sử dụng password thay vì key
echo "Cấu hình SSH cho phép đăng nhập bằng password..."
sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config
systemctl restart ssh

# Tạo nmpanel script
echo "Tạo script nmpanel..."
cat > /usr/local/bin/nmpanel <<'EOF'
#!/bin/bash

# Biến màu cho hiển thị
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Lấy thông tin hệ thống
get_system_info() {
    echo -e "${BLUE}=== THÔNG TIN HỆ THỐNG ===${NC}"
    echo -e "${CYAN}Hostname:${NC} $(hostname)"
    echo -e "${CYAN}OS:${NC} $(lsb_release -ds)"
    echo -e "${CYAN}Kernel:${NC} $(uname -r)"
    echo -e "${CYAN}Uptime:${NC} $(uptime -p)"
    echo -e "${CYAN}CPU:${NC} $(grep -c ^processor /proc/cpuinfo) cores"
    echo -e "${CYAN}Load:${NC} $(cat /proc/loadavg | awk '{print $1, $2, $3}')"
    echo -e "${CYAN}RAM:${NC} $(free -h | grep Mem | awk '{print "Total: " $2 "  Used: " $3 "  Free: " $4}')"
    echo -e "${CYAN}Disk:${NC} $(df -h / | grep / | awk '{print "Total: " $2 "  Used: " $3 "  Free: " $4 "  Usage: " $5}')"
    echo -e "${CYAN}IP Chính:${NC} $(curl -s ifconfig.me)"
}

# Kiểm tra các dịch vụ
check_services() {
    echo -e "${BLUE}=== TRẠNG THÁI DỊCH VỤ ===${NC}"
    services=("nginx" "mongod" "postfix" "opendkim" "fail2ban")
    
    for service in "${services[@]}"; do
        status=$(systemctl is-active $service)
        if [ "$status" = "active" ]; then
            echo -e "${CYAN}$service:${NC} ${GREEN}Đang chạy${NC}"
        else
            echo -e "${CYAN}$service:${NC} ${RED}Không chạy${NC}"
        fi
    done
    
    echo -e "${CYAN}Node.js:${NC} $(node -v)"
    echo -e "${CYAN}PM2:${NC} $(pm2 --version)"
    echo -e "${CYAN}Apps đang chạy:${NC} $(pm2 list | grep -c online) ứng dụng"
}

# Xem log
view_logs() {
    echo -e "${BLUE}=== XEM LOG ===${NC}"
    echo "1) NGINX access log"
    echo "2) NGINX error log"
    echo "3) PM2 logs"
    echo "4) Fail2ban log"
    echo "5) Auth log (SSH)"
    echo "0) Quay lại"
    
    read -p "Chọn loại log: " log_choice
    
    case $log_choice in
        1) less +G /var/log/nginx/access.log ;;
        2) less +G /var/log/nginx/error.log ;;
        3) pm2 logs ;;
        4) less +G /var/log/fail2ban.log ;;
        5) less +G /var/log/auth.log ;;
        0) return ;;
        *) echo "Lựa chọn không hợp lệ" ;;
    esac
}

# Xem các IP bị chặn
view_banned_ips() {
    echo -e "${BLUE}=== IP BỊ CHẶN ===${NC}"
    echo -e "${CYAN}IP bị Fail2ban chặn:${NC}"
    fail2ban-client status | grep "Jail list" | sed 's/^.*://g' | sed 's/,//g' | while read -r jail; do
        echo -e "${YELLOW}$jail:${NC}"
        fail2ban-client status "$jail" | grep -E "IP list|Currently banned|Total banned"
    done
}

# Thêm domain/app mới
add_new_app() {
    echo -e "${BLUE}=== THÊM APP/DOMAIN MỚI ===${NC}"
    read -p "Nhập domain mới: " new_domain
    
    # Tự động tạo APP_PATH từ domain
    new_app_path="/var/www/nodejs/$(echo $new_domain | tr '.' '_')"
    echo "Đường dẫn ứng dụng tự động: $new_app_path"
    read -p "Sử dụng đường dẫn này? (y/n): " use_auto_path
    
    if [[ "$use_auto_path" != "y" && "$use_auto_path" != "Y" ]]; then
        read -p "Nhập đường dẫn app tùy chỉnh: " new_app_path
    fi
    
    read -p "Nhập port: " new_app_port
    
    # Kiểm tra đường dẫn
    if [ ! -d "$new_app_path" ]; then
        echo "Tạo thư mục $new_app_path..."
        mkdir -p "$new_app_path"
    fi
    
    # Thêm config NGINX
    echo "Tạo cấu hình NGINX..."
    cat > /etc/nginx/sites-available/${new_domain}.conf <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${new_domain};
    
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF

    # Tạo symlink
    ln -sf /etc/nginx/sites-available/${new_domain}.conf /etc/nginx/sites-enabled/
    
    # Kiểm tra cấu hình NGINX
    nginx -t && systemctl reload nginx
    
    # Lấy chứng chỉ SSL từ Let's Encrypt
    certbot certonly --webroot -w /var/www/certbot -d ${new_domain} --agree-tos --register-unsafely-without-email --non-interactive
    
    # Cấu hình HTTPS
    cat > /etc/nginx/sites-available/${new_domain}-ssl.conf <<EOF
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${new_domain};
    
    ssl_certificate /etc/letsencrypt/live/${new_domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${new_domain}/privkey.pem;
    
    location / {
        proxy_pass http://localhost:${new_app_port};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

    ln -sf /etc/nginx/sites-available/${new_domain}-ssl.conf /etc/nginx/sites-enabled/
    nginx -t && systemctl reload nginx
    
    echo -e "${GREEN}Đã thêm domain ${new_domain} thành công!${NC}"
}

# Quản lý database
manage_database() {
    echo -e "${BLUE}=== QUẢN LÝ DATABASE ===${NC}"
    echo "1) Tạo database mới"
    echo "2) Liệt kê databases hiện có"
    echo "3) Backup database"
    echo "4) Restore database"
    echo "0) Quay lại"
    
    read -p "Chọn: " db_choice
    
    case $db_choice in
        1)
            read -p "Tên database mới: " db_name
            mongosh admin --eval "db.getSiblingDB('$db_name').createCollection('init')"
            echo -e "${GREEN}Đã tạo database $db_name${NC}"
            ;;
        2)
            echo -e "${CYAN}Danh sách databases:${NC}"
            mongosh --eval "db.adminCommand('listDatabases')"
            ;;
        3)
            read -p "Tên database để backup: " db_name
            BACKUP_DIR="/var/backups/mongodb"
            mkdir -p $BACKUP_DIR
            BACKUP_FILE="$BACKUP_DIR/${db_name}_$(date +%Y%m%d_%H%M%S).gz"
            mongodump --db=$db_name --gzip --archive=$BACKUP_FILE
            echo -e "${GREEN}Đã backup database $db_name vào $BACKUP_FILE${NC}"
            ;;
        4)
            echo "Các file backup có sẵn:"
            ls -lh /var/backups/mongodb/
            read -p "Nhập đường dẫn file backup để restore: " backup_file
            read -p "Restore vào database: " db_name
            mongorestore --gzip --archive=$backup_file --nsFrom="$db_name.*" --nsTo="$db_name.*"
            echo -e "${GREEN}Đã restore database $db_name từ $backup_file${NC}"
            ;;
        0) return ;;
        *) echo "Lựa chọn không hợp lệ" ;;
    esac
}

# Quản lý PM2
manage_pm2() {
    echo -e "${BLUE}=== QUẢN LÝ PM2 ===${NC}"
    echo "1) Xem danh sách apps"
    echo "2) Khởi động lại tất cả apps"
    echo "3) Khởi động lại app cụ thể"
    echo "4) Dừng app"
    echo "5) Xem logs"
    echo "6) Theo dõi monit"
    echo "0) Quay lại"
    
    read -p "Chọn: " pm2_choice
    
    case $pm2_choice in
        1) pm2 list ;;
        2) pm2 restart all ;;
        3)
            pm2 list
            read -p "Nhập ID hoặc tên app để khởi động lại: " app_id
            pm2 restart $app_id
            ;;
        4)
            pm2 list
            read -p "Nhập ID hoặc tên app để dừng: " app_id
            pm2 stop $app_id
            ;;
        5) pm2 logs ;;
        6) pm2 monit ;;
        0) return ;;
        *) echo "Lựa chọn không hợp lệ" ;;
    esac
}

# Quản lý SSL
manage_ssl() {
    echo -e "${BLUE}=== QUẢN LÝ SSL ===${NC}"
    echo "1) Xem danh sách chứng chỉ"
    echo "2) Gia hạn thủ công tất cả chứng chỉ"
    echo "3) Gia hạn thủ công chứng chỉ cụ thể"
    echo "0) Quay lại"
    
    read -p "Chọn: " ssl_choice
    
    case $ssl_choice in
        1) certbot certificates ;;
        2) 
            certbot renew
            systemctl reload nginx
            ;;
        3)
            certbot certificates
            read -p "Nhập domain để gia hạn: " ssl_domain
            certbot certonly --force-renewal -d $ssl_domain
            systemctl reload nginx
            ;;
        0) return ;;
        *) echo "Lựa chọn không hợp lệ" ;;
    esac
}

# Main menu
main_menu() {
    clear
    echo -e "${GREEN}=======================================================${NC}"
    echo -e "${YELLOW}                 NmPanel MANAGEMENT MENU                ${NC}"
    echo -e "${GREEN}=======================================================${NC}"
    echo -e "${BLUE}Ngày giờ:${NC} $(date)"
    echo -e "${BLUE}User:${NC} $(whoami)"
    echo -e "${GREEN}=======================================================${NC}"
    
    echo "1) Xem thông tin hệ thống"
    echo "2) Kiểm tra trạng thái dịch vụ"
    echo "3) Xem logs"
    echo "4) Xem IP bị chặn"
    echo "5) Thêm app/domain mới"
    echo "6) Quản lý database"
    echo "7) Quản lý PM2"
    echo "8) Quản lý SSL"
    echo "9) Khởi động lại dịch vụ"
    echo "0) Thoát"
    
    read -p "Nhập lựa chọn của bạn: " choice
    
    case $choice in
        1) get_system_info ;;
        2) check_services ;;
        3) view_logs ;;
        4) view_banned_ips ;;
        5) add_new_app ;;
        6) manage_database ;;
        7) manage_pm2 ;;
        8) manage_ssl ;;
        9)
            echo "1) Khởi động lại NGINX"
            echo "2) Khởi động lại MongoDB"
            echo "3) Khởi động lại Postfix"
            echo "4) Khởi động lại tất cả"
            read -p "Chọn dịch vụ: " service_choice
            
            case $service_choice in
                1) systemctl restart nginx ;;
                2) systemctl restart mongod ;;
                3) systemctl restart postfix ;;
                4) 
                    systemctl restart nginx
                    systemctl restart mongod
                    systemctl restart postfix
                    systemctl restart opendkim
                    systemctl restart fail2ban
                    ;;
                *) echo "Lựa chọn không hợp lệ" ;;
            esac
            ;;
        0) exit 0 ;;
        *) echo "Lựa chọn không hợp lệ, vui lòng thử lại" ;;
    esac
    
    echo ""
    read -p "Nhấn Enter để tiếp tục..."
    main_menu
}

# Kiểm tra xem người dùng có quyền root không
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}⚠️ Cảnh báo: Script này nên được chạy với quyền root (sudo)${NC}"
    exit 1
fi

# Chạy menu chính
main_menu
EOF

chmod +x /usr/local/bin/nmpanel

# DNS hướng dẫn
echo -e "\n🎯 Thêm bản ghi DNS cho domain của bạn:"
SERVER_IP=$(curl -s ifconfig.me || curl -s icanhazip.com || curl -s ipinfo.io/ip)
echo "A      ${DOMAIN}         → ${SERVER_IP}"
echo "A      ${MAIL_DOMAIN}    → ${SERVER_IP}"
echo "MX     ${DOMAIN}         → mail.${DOMAIN} (priority 10)"
echo "TXT    ${DOMAIN}         → v=spf1 mx a ~all"
echo "TXT    _dmarc.${DOMAIN}  → v=DMARC1; p=none"
echo "TXT    mail._domainkey.${DOMAIN} →"
cat /etc/opendkim/keys/${DOMAIN}/mail.txt

# Tạo file thông tin hệ thống
cat > ${APP_PATH}/server-info.txt <<EOF
=============================================
SERVER INFORMATION (Generated: $(date))
=============================================

SERVER:
- IP: ${SERVER_IP}
- Hostname: $(hostname)
- OS: $(lsb_release -ds)
- Kernel: $(uname -r)
- CPU: ${CPU_CORES} cores
- RAM: ${TOTAL_RAM_GB}GB
- Disk: $(df -h / | grep / | awk '{print $2}')

SERVICES:
- Node.js: $(node -v)
- NPM: $(npm -v)
- MongoDB: $(mongod --version | head -n 1) (port 27017)
- NGINX: $(nginx -v 2>&1)
- PM2: $(pm2 --version)

APPLICATION:
- Path: ${APP_PATH}
- Main: ${MAIN_JS}
- Domain: https://${DOMAIN}
- Port: ${APP_PORT}
- PM2 instances: max (sử dụng tất cả ${CPU_CORES} cores)
- PM2 max_memory: ${MAX_MEMORY}

USEFUL COMMANDS:
- Quản lý VPS: nmpanel
- Restart NGINX: systemctl restart nginx
- View NGINX logs: tail -f /var/log/nginx/${DOMAIN}.ssl-access.log
- Restart app: cd ${APP_PATH} && pm2 restart all
- View app logs: cd ${APP_PATH} && pm2 logs
- MongoDB shell: mongosh
EOF

# Hoàn tất
echo -e "\n✅ Cài đặt hoàn tất! ($(date -u '+%Y-%m-%d %H:%M:%S'))"
echo "🌐 Truy cập website: https://${DOMAIN}"
echo "📂 Đường dẫn ứng dụng Node.js: ${APP_PATH}/${MAIN_JS}"
echo "🚀 Status ứng dụng: $(cd ${APP_PATH} && pm2 status)"
echo "🔒 Chứng chỉ SSL Let's Encrypt sẽ tự động gia hạn"
echo "📝 Thông tin đầy đủ: ${APP_PATH}/server-info.txt"
echo "📋 Log cài đặt: $LOG_FILE"
echo -e "\n💡 HƯỚNG DẪN SỬ DỤNG:"
echo "   - Gõ lệnh 'nmpanel' để mở menu quản lý hệ thống"
echo "   - SSH đăng nhập bằng password đã được bật"
echo "   - PM2 đã được cấu hình sử dụng tất cả CPU cores"
echo "   - Mỗi instance PM2 sử dụng tối đa ${MAX_MEMORY} RAM"
echo "   - Shortcut đến ứng dụng: ./${APP_DIR_NAME}"
echo "   - MongoDB được cấu hình sử dụng local port 27017"
echo -e "\n${GREEN}Cảm ơn bạn đã sử dụng script cài đặt VPS của nttrung9x!${NC}"
