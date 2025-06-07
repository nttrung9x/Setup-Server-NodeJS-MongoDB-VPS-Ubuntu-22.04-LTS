#!/bin/bash

# ===========================
# NmPanel Management Script
# Quản lý VPS Node.js - MongoDB một cách dễ dàng
# Tác giả: nttrung9x - FB/hkvn9x - 0372.972.971
# Ngày tạo: 2025-06-06
# Phiên bản: 2.1
# ===========================

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Load server configuration if exists
SERVER_CONFIG_FILE="/var/lib/nmpanel/server-config.json"
if [ -f "$SERVER_CONFIG_FILE" ]; then
    DOMAIN=$(grep '"domain"' $SERVER_CONFIG_FILE | cut -d'"' -f4)
    MAIL_DOMAIN=$(grep '"mail_domain"' $SERVER_CONFIG_FILE | cut -d'"' -f4)
    APP_PATH=$(grep '"app_path"' $SERVER_CONFIG_FILE | cut -d'"' -f4)
    MAIN_JS=$(grep '"main_js"' $SERVER_CONFIG_FILE | cut -d'"' -f4)
    APP_PORT=$(grep '"app_port"' $SERVER_CONFIG_FILE | cut -d'"' -f4)
fi

# Xem thông tin hệ thống
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
    echo -e "${CYAN}IP Chính:${NC} $(curl -s ifconfig.me 2>/dev/null || echo "N/A")"
    
    # Node.js info if available
    if command -v node >/dev/null 2>&1; then
        echo -e "${CYAN}Node.js:${NC} $(node -v)"
        echo -e "${CYAN}PM2:${NC} $(pm2 --version 2>/dev/null || echo "N/A")"
        echo -e "${CYAN}Apps đang chạy:${NC} $(pm2 list 2>/dev/null | grep -c online || echo "0") ứng dụng"
    fi
}

# Kiểm tra các dịch vụ
check_services() {
    echo -e "${BLUE}=== TRẠNG THÁI DỊCH VỤ ===${NC}"
    services=("nginx" "mongod" "postfix" "opendkim" "fail2ban")
    
    for service in "${services[@]}"; do
        if systemctl is-active --quiet $service 2>/dev/null; then
            echo -e "${CYAN}$service:${NC} ${GREEN}Đang chạy${NC}"
        else
            echo -e "${CYAN}$service:${NC} ${RED}Không chạy${NC}"
        fi
    done
    
    # PM2 status
    if command -v pm2 >/dev/null 2>&1; then
        echo -e "\n${BLUE}=== PM2 STATUS ===${NC}"
        pm2 list 2>/dev/null || echo "PM2 không có ứng dụng nào đang chạy"
    fi
}

# Xem log
view_logs() {
    echo -e "${BLUE}=== XEM LOG ===${NC}"
    echo "1) NGINX access log"
    echo "2) NGINX error log"
    echo "3) PM2 logs"
    echo "4) Fail2ban log"
    echo "5) Auth log (SSH)"
    echo "6) MongoDB log"
    echo "7) Postfix log"
    echo "0) Quay lại"
    
    read -p "Chọn loại log: " log_choice
    
    case $log_choice in
        1) 
            if [ -n "$DOMAIN" ]; then
                less +G /var/log/nginx/${DOMAIN}*.log 2>/dev/null || less +G /var/log/nginx/access.log
            else
                less +G /var/log/nginx/access.log
            fi
            ;;
        2) 
            if [ -n "$DOMAIN" ]; then
                less +G /var/log/nginx/${DOMAIN}*.error.log 2>/dev/null || less +G /var/log/nginx/error.log
            else
                less +G /var/log/nginx/error.log
            fi
            ;;
        3) 
            if command -v pm2 >/dev/null 2>&1; then
                pm2 logs
            else
                echo "PM2 không được cài đặt"
            fi
            ;;
        4) less +G /var/log/fail2ban.log ;;
        5) less +G /var/log/auth.log ;;
        6) less +G /var/log/mongodb/mongod.log ;;
        7) less +G /var/log/mail.log ;;
        0) return ;;
        *) echo "Lựa chọn không hợp lệ" ;;
    esac
}

# Xem các IP bị chặn
view_banned_ips() {
    echo -e "${BLUE}=== IP BỊ CHẶN ===${NC}"
    if command -v fail2ban-client >/dev/null 2>&1; then
        echo -e "${CYAN}IP bị Fail2ban chặn:${NC}"
        fail2ban-client status 2>/dev/null | grep "Jail list" | sed 's/^.*://g' | sed 's/,//g' | while read -r jail; do
            if [ -n "$jail" ]; then
                echo -e "${YELLOW}$jail:${NC}"
                fail2ban-client status "$jail" 2>/dev/null | grep -E "IP list|Currently banned|Total banned"
            fi
        done
    else
        echo "Fail2ban không được cài đặt hoặc không chạy"
    fi
}

# Thêm domain/app mới
add_new_app() {
    echo -e "${BLUE}=== THÊM APP/DOMAIN MỚI ===${NC}"
    
    read -p "Nhập domain mới: " new_domain
    if [ -z "$new_domain" ]; then
        echo "❌ Domain không được để trống"
        return 1
    fi
    
    # Validate domain format
    if ! echo "$new_domain" | grep -E '^[a-zA-Z0-9][a-zA-Z0-9-]{1,61}[a-zA-Z0-9]\.[a-zA-Z]{2,}$' >/dev/null; then
        echo "❌ Domain không hợp lệ"
        return 1
    fi
    
    # Tự động tạo APP_PATH từ domain
    new_app_path="/var/www/nodejs/$(echo $new_domain | tr '.' '_')"
    echo "Đường dẫn ứng dụng tự động: $new_app_path"
    read -p "Sử dụng đường dẫn này? (y/n): " use_auto_path
    
    if [[ "$use_auto_path" != "y" && "$use_auto_path" != "Y" ]]; then
        read -p "Nhập đường dẫn app tùy chỉnh: " new_app_path
    fi
    
    read -p "Nhập port: " new_app_port
    if ! [[ "$new_app_port" =~ ^[0-9]+$ ]] || [ "$new_app_port" -lt 1 ] || [ "$new_app_port" -gt 65535 ]; then
        echo "❌ Port không hợp lệ (phải từ 1-65535)"
        return 1
    fi
    
    # Kiểm tra đường dẫn
    if [ ! -d "$new_app_path" ]; then
        echo "Tạo thư mục $new_app_path..."
        mkdir -p "$new_app_path"
    fi
    
    # Thêm config NGINX HTTP
    echo "Tạo cấu hình NGINX..."
    cat > /etc/nginx/sites-available/${new_domain}.conf <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${new_domain};

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
        try_files \$uri =404;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF

    # Tạo symlink
    ln -sf /etc/nginx/sites-available/${new_domain}.conf /etc/nginx/sites-enabled/
    
    # Kiểm tra cấu hình NGINX
    if ! nginx -t; then
        echo "❌ Cấu hình NGINX có lỗi"
        rm -f /etc/nginx/sites-enabled/${new_domain}.conf
        return 1
    fi
    
    systemctl reload nginx
    
    # Lấy chứng chỉ SSL từ Let's Encrypt
    echo "🔒 Đang lấy SSL certificate cho ${new_domain}..."
    mkdir -p /var/www/certbot
    chown -R www-data:www-data /var/www/certbot
    
    if certbot certonly --webroot -w /var/www/certbot -d "${new_domain}" --agree-tos --register-unsafely-without-email --non-interactive; then
        echo "✅ SSL certificate đã được tạo thành công cho ${new_domain}"
        
        # Tạo config HTTPS
        cat > /etc/nginx/sites-available/${new_domain}-ssl.conf <<EOF
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${new_domain};
    
    # Ghi log chi tiết cho việc gỡ lỗi
    access_log /var/log/nginx/${new_domain}.ssl-access.log;
    error_log /var/log/nginx/${new_domain}.ssl-error.log;

    # Cấu hình SSL
    ssl_certificate /etc/letsencrypt/live/${new_domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${new_domain}/privkey.pem;
    ssl_trusted_certificate /etc/letsencrypt/live/${new_domain}/chain.pem;
    ssl_dhparam /etc/nginx/ssl/dhparam.pem;

    # Các tham số bảo mật SSL 
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;
    ssl_stapling off;
    ssl_stapling_verify off;
    resolver 8.8.8.8 8.8.4.4 valid=300s;
    resolver_timeout 5s;
    
    # Thiết lập HSTS
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;

    # Bảo mật bổ sung
    add_header X-Content-Type-Options "nosniff" always;
	add_header X-Frame-Options "DENY" always;
	add_header X-XSS-Protection "1; mode=block" always;
	add_header Referrer-Policy "strict-origin-when-cross-origin" always;
	add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval' https://cdn.jsdelivr.net https://cdnjs.cloudflare.com; script-src-attr 'unsafe-inline'; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com https://cdn.jsdelivr.net https://cdnjs.cloudflare.com; font-src 'self' https://fonts.gstatic.com https://cdnjs.cloudflare.com; img-src 'self' data:; connect-src 'self';" always;
	add_header Permissions-Policy "geolocation=(), microphone=(), camera=()" always;



    # *** Thêm header CORS allow all ***
    add_header Access-Control-Allow-Origin "*" always;
    add_header Access-Control-Allow-Methods "GET, POST, OPTIONS, PUT, DELETE" always;
    add_header Access-Control-Allow-Headers "Authorization,Content-Type,Accept" always;

    # Giới hạn kích thước body
    client_max_body_size 10M;

    # Bảo vệ một số tệp nhạy cảm
    location ~ /\.(?!well-known) {
        deny all;
    }
    
    # Đường dẫn tĩnh - phục vụ trực tiếp không qua Node.js
    location ~* \.(jpg|jpeg|png|gif|ico|css|js|svg|woff|woff2|ttf|eot)\$ {
        root /var/www/nodejs/tflogin_com/public;
        expires 30d;
        add_header Cache-Control "public, no-transform";
        
        # Thêm CORS cho static files
        add_header Access-Control-Allow-Origin "*" always;
        add_header Access-Control-Allow-Methods "GET, POST, OPTIONS, PUT, DELETE" always;
        add_header Access-Control-Allow-Headers "Authorization,Content-Type,Accept" always;
        
        try_files \$uri \$uri/ @proxy;
    }
    
    # Tất cả request khác chuyển đến Node.js
    location / {
        # Thiết lập proxy headers
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        # Các cấu hình proxy khác
        proxy_pass http://localhost:${new_app_port};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
        proxy_buffering off;
        proxy_read_timeout 120s;
        proxy_connect_timeout 10s;
        proxy_send_timeout 120s;

        # Thêm CORS cho proxy responses
        add_header Access-Control-Allow-Origin "*" always;
        add_header Access-Control-Allow-Methods "GET, POST, OPTIONS, PUT, DELETE" always;
        add_header Access-Control-Allow-Headers "Authorization,Content-Type,Accept" always;
        
        # Rate limiting cơ bản để tránh tấn công
        limit_req zone=one burst=10 nodelay;
        limit_conn addr 10;

        # Trả về nhanh cho OPTIONS preflight request
        if (\$request_method = OPTIONS ) {
            add_header Access-Control-Max-Age 1728000;
            add_header Content-Type "text/plain; charset=UTF-8";
            add_header Content-Length 0;
            return 204;
        }
    }
    
    # Fallback cho static files
    location @proxy {
        proxy_pass http://localhost:${new_app_port};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;

        # Thêm CORS cho fallback
        add_header Access-Control-Allow-Origin "*" always;
        add_header Access-Control-Allow-Methods "GET, POST, OPTIONS, PUT, DELETE" always;
        add_header Access-Control-Allow-Headers "Authorization,Content-Type,Accept" always;
    }
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name mail.${new_domain};

    ssl_certificate /etc/letsencrypt/live/${new_domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${new_domain}/privkey.pem;
    ssl_trusted_certificate /etc/letsencrypt/live/${new_domain}/chain.pem;
    
    # Cấu hình bảo mật SSL tương tự
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;
    
    # Trang chào mail server
    location / {
        add_header Content-Type text/plain;
        return 200 "Mail server for mail.\${new_domain}";
    }
}
EOF
        
        ln -sf /etc/nginx/sites-available/${new_domain}-ssl.conf /etc/nginx/sites-enabled/
        nginx -t && systemctl reload nginx
        
    else
        echo "❌ Không thể tạo SSL certificate cho ${new_domain}"
        echo "⚠️ Sẽ tạo config HTTP-only"
        
        # Tạo config HTTP-only nếu SSL thất bại
        cat > /etc/nginx/sites-available/${new_domain}-http.conf <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${new_domain};
    
    location / {
        proxy_pass http://localhost:${new_app_port};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
        
        # Remove redirect config and use HTTP-only
        rm -f /etc/nginx/sites-enabled/${new_domain}.conf
        ln -sf /etc/nginx/sites-available/${new_domain}-http.conf /etc/nginx/sites-enabled/
        nginx -t && systemctl reload nginx
    fi
    
    echo -e "${GREEN}Đã thêm domain ${new_domain} thành công!${NC}"
    echo "📝 Đường dẫn app: $new_app_path"
    echo "🌐 Port: $new_app_port"
    echo "💡 Đừng quên tạo ứng dụng Node.js tại $new_app_path và khởi động với PM2"
}

# Quản lý database
manage_database() {
    echo -e "${BLUE}=== QUẢN LÝ DATABASE ===${NC}"
    echo "1) Tạo database mới"
    echo "2) Liệt kê databases hiện có"
    echo "3) Backup database"
    echo "4) Restore database"
    echo "5) Xóa database"
    echo "0) Quay lại"
    
    read -p "Chọn: " db_choice
    
    case $db_choice in
        1)
            read -p "Tên database mới: " db_name
            if [ -n "$db_name" ]; then
                if command -v mongosh >/dev/null 2>&1; then
                    mongosh admin --eval "db.getSiblingDB('$db_name').createCollection('init')"
                    echo -e "${GREEN}Đã tạo database $db_name${NC}"
                else
                    echo "MongoDB shell không có sẵn"
                fi
            fi
            ;;
        2)
            if command -v mongosh >/dev/null 2>&1; then
                echo "Danh sách databases:"
                mongosh admin --quiet --eval "db.adminCommand('listDatabases').databases.forEach(function(db) { print(db.name + ' - ' + (db.sizeOnDisk/1024/1024).toFixed(2) + ' MB') })"
            else
                echo "MongoDB shell không có sẵn"
            fi
            ;;
        3)
            read -p "Tên database cần backup: " db_name
            if [ -n "$db_name" ]; then
                BACKUP_DIR="/var/backups/mongodb"
                mkdir -p $BACKUP_DIR
                BACKUP_FILE="$BACKUP_DIR/${db_name}_$(date +%Y%m%d_%H%M%S).gz"
                if command -v mongodump >/dev/null 2>&1; then
                    mongodump --db $db_name --gzip --archive=$BACKUP_FILE
                    echo -e "${GREEN}Đã backup database $db_name vào $BACKUP_FILE${NC}"
                else
                    echo "mongodump không có sẵn"
                fi
            fi
            ;;
        4)
            echo "Các file backup có sẵn:"
            ls -lh /var/backups/mongodb/ 2>/dev/null || echo "Không có backup nào"
            read -p "Nhập đường dẫn file backup để restore: " backup_file
            if [ -f "$backup_file" ]; then
                read -p "Restore vào database: " db_name
                if command -v mongorestore >/dev/null 2>&1; then
                    mongorestore --gzip --archive=$backup_file --nsFrom="$db_name.*" --nsTo="$db_name.*"
                    echo -e "${GREEN}Đã restore database $db_name từ $backup_file${NC}"
                else
                    echo "mongorestore không có sẵn"
                fi
            else
                echo "File backup không tồn tại"
            fi
            ;;
        5)
            read -p "Tên database cần xóa: " db_name
            read -p "⚠️ Bạn có chắc chắn muốn xóa database '$db_name'? (yes/no): " confirm
            if [[ "$confirm" == "yes" ]]; then
                if command -v mongosh >/dev/null 2>&1; then
                    mongosh admin --eval "db.getSiblingDB('$db_name').dropDatabase()"
                    echo -e "${GREEN}Đã xóa database $db_name${NC}"
                else
                    echo "MongoDB shell không có sẵn"
                fi
            else
                echo "Hủy thao tác xóa database"
            fi
            ;;
        0) return ;;
        *) echo "Lựa chọn không hợp lệ" ;;
    esac
}

# Quản lý PM2
manage_pm2() {
    echo -e "${BLUE}=== QUẢN LÝ PM2 ===${NC}"
    
    if ! command -v pm2 >/dev/null 2>&1; then
        echo "PM2 không được cài đặt"
        return 1
    fi
    
    echo "1) Xem danh sách apps"
    echo "2) Khởi động lại tất cả apps"
    echo "3) Khởi động lại app cụ thể"
    echo "4) Dừng app"
    echo "5) Xóa app"
    echo "6) Xem logs"
    echo "7) Theo dõi monit"
    echo "8) Tạo app mới từ file"
    echo "0) Quay lại"
    
    read -p "Chọn: " pm2_choice
    
    case $pm2_choice in
        1) pm2 list ;;
        2) pm2 restart all ;;
        3)
            pm2 list
            read -p "Nhập ID hoặc tên app để khởi động lại: " app_id
            if [ -n "$app_id" ]; then
                pm2 restart $app_id
            fi
            ;;
        4)
            pm2 list
            read -p "Nhập ID hoặc tên app để dừng: " app_id
            if [ -n "$app_id" ]; then
                pm2 stop $app_id
            fi
            ;;
        5)
            pm2 list
            read -p "Nhập ID hoặc tên app để xóa: " app_id
            if [ -n "$app_id" ]; then
                read -p "⚠️ Bạn có chắc chắn muốn xóa app '$app_id'? (y/n): " confirm
                if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                    pm2 delete $app_id
                fi
            fi
            ;;
        6) pm2 logs ;;
        7) pm2 monit ;;
        8)
            read -p "Đường dẫn file JS: " js_file
            read -p "Tên app: " app_name
            read -p "Số instances (max cho auto): " instances
            if [ -f "$js_file" ] && [ -n "$app_name" ]; then
                pm2 start $js_file --name $app_name --instances ${instances:-max}
                pm2 save
            else
                echo "File không tồn tại hoặc tên app trống"
            fi
            ;;
        0) return ;;
        *) echo "Lựa chọn không hợp lệ" ;;
    esac
}

# Quản lý SSL
manage_ssl() {
    echo -e "${BLUE}=== QUẢN LÝ SSL ===${NC}"
    
    if ! command -v certbot >/dev/null 2>&1; then
        echo "Certbot không được cài đặt"
        return 1
    fi
    
    echo "1) Xem danh sách chứng chỉ"
    echo "2) Gia hạn thủ công tất cả chứng chỉ"
    echo "3) Gia hạn thủ công chứng chỉ cụ thể"
    echo "4) Tạo chứng chỉ mới"
    echo "0) Quay lại"
    
    read -p "Chọn: " ssl_choice
    
    case $ssl_choice in
        1) certbot certificates ;;
        2) 
            certbot renew
            systemctl reload nginx
            echo "✅ Đã gia hạn tất cả chứng chỉ"
            ;;
        3)
            certbot certificates
            read -p "Nhập domain để gia hạn: " ssl_domain
            if [ -n "$ssl_domain" ]; then
                certbot certonly --force-renewal -d $ssl_domain
                systemctl reload nginx
                echo "✅ Đã gia hạn chứng chỉ cho $ssl_domain"
            fi
            ;;
        4)
            read -p "Nhập domain mới: " new_ssl_domain
            if [ -n "$new_ssl_domain" ]; then
                mkdir -p /var/www/certbot
                chown -R www-data:www-data /var/www/certbot
                certbot certonly --webroot -w /var/www/certbot -d "$new_ssl_domain" --agree-tos --register-unsafely-without-email --non-interactive
            fi
            ;;
        0) return ;;
        *) echo "Lựa chọn không hợp lệ" ;;
    esac
}

# Restart services
restart_services() {
    echo -e "${BLUE}=== KHỞI ĐỘNG LẠI DỊCH VỤ ===${NC}"
    echo "1) Khởi động lại NGINX"
    echo "2) Khởi động lại MongoDB"
    echo "3) Khởi động lại Postfix"
    echo "4) Khởi động lại PM2"
    echo "5) Khởi động lại tất cả"
    echo "0) Quay lại"
    
    read -p "Chọn dịch vụ: " service_choice
    
    case $service_choice in
        1) 
            systemctl restart nginx && echo "✅ NGINX đã được khởi động lại" || echo "❌ Lỗi khởi động lại NGINX"
            ;;
        2) 
            systemctl restart mongod && echo "✅ MongoDB đã được khởi động lại" || echo "❌ Lỗi khởi động lại MongoDB"
            ;;
        3) 
            systemctl restart postfix && echo "✅ Postfix đã được khởi động lại" || echo "❌ Lỗi khởi động lại Postfix"
            ;;
        4)
            if command -v pm2 >/dev/null 2>&1; then
                pm2 restart all && echo "✅ PM2 đã được khởi động lại" || echo "❌ Lỗi khởi động lại PM2"
            else
                echo "PM2 không được cài đặt"
            fi
            ;;
        5) 
            echo "🔄 Khởi động lại tất cả services..."
            systemctl restart nginx mongod postfix opendkim fail2ban
            if command -v pm2 >/dev/null 2>&1; then
                pm2 restart all
            fi
            echo "✅ Đã khởi động lại tất cả!"
            ;;
        0) return ;;
        *) echo "Lựa chọn không hợp lệ" ;;
    esac
}

# Main menu
main_menu() {
    while true; do
        clear
        echo -e "${GREEN}=======================================================${NC}"
        echo -e "${YELLOW}                 NmPanel MANAGEMENT MENU                ${NC}"
        echo -e "${GREEN}=======================================================${NC}"
        echo -e "${BLUE}Ngày giờ:${NC} $(date)"
        echo -e "${BLUE}User:${NC} $(whoami)"
        if [ -n "$DOMAIN" ]; then
            echo -e "${BLUE}Domain:${NC} $DOMAIN"
        fi
        echo -e "${GREEN}=======================================================${NC}"
        
        echo "1) Quản lý PM2"
        echo "2) Xem logs"
        echo "3) Kiểm tra trạng thái dịch vụ"
        echo "4) Xem IP bị chặn"
        echo "5) Quản lý database"
        echo "6) Quản lý SSL"
        echo "7) Thêm app/domain mới"
        echo "8) Xem thông tin hệ thống"
        echo "9) Khởi động lại dịch vụ"
        echo "0) Thoát"

        read -p "Nhập lựa chọn của bạn: " choice

        case $choice in
            1) manage_pm2 ;;
            2) view_logs ;;
            3) check_services ;;
            4) view_banned_ips ;;
            5) manage_database ;;
            6) manage_ssl ;;
            7) add_new_app ;;
            8) get_system_info ;;
            9) restart_services ;;
            0)
                echo "👋 Tạm biệt!"
                exit 0 
                ;;
            *) echo "Lựa chọn không hợp lệ, vui lòng thử lại" ;;
        esac
        
        echo ""
        read -p "Nhấn Enter để tiếp tục..."
    done
}

# Kiểm tra quyền root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}⚠️ Cảnh báo: Script này nên được chạy với quyền root (sudo)${NC}"
    exit 1
fi

# Chạy menu chính
main_menu
