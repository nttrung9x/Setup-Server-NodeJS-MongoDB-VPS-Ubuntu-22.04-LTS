#!/bin/bash

# ===========================
# VPS Setup Script for Ubuntu 22.04 LTS (Updated: 2025-06-06)
# - Node.js app with Express + Cluster
# - MongoDB database (local usage)
# - NGINX reverse proxy with Let's Encrypt SSL
# - Postfix + OpenDKIM for sending email
# - With cleanup and retry functionality
# ===========================

set -e

# Hiển thị thông tin
echo "======================================================="
echo "🚀 VPS SETUP SCRIPT - Phiên bản 2.1 (Enhanced)"
echo "🗓️ Ngày cập nhật: 2025-06-06 12:00:00"
echo "👤 Tác giả: nttrung9x - FB/hkvn9x - 0372.972.971"
echo "✨ Tính năng mới: Cleanup & Retry khi lỗi"
echo "======================================================="

# Biến global để lưu trạng thái cài đặt
SCRIPT_DIR_NMPANEL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLED_COMPONENTS=()
FAILED_COMPONENTS=()

# Hàm cleanup - Gỡ bỏ các thành phần đã cài
cleanup_installation() {
    echo "🧹 Đang thực hiện cleanup các thành phần đã cài..."
    
    # Dừng và xóa PM2 processes
    if command -v pm2 >/dev/null 2>&1; then
        echo "Dừng và xóa PM2 processes..."
        pm2 kill || true
        pm2 unstartup || true
    fi
    
    # Dừng các services
    echo "Dừng các services..."
    systemctl stop nginx || true
    systemctl stop mongod || true
    systemctl stop postfix || true
    systemctl stop opendkim || true
    systemctl stop fail2ban || true
    
    # Xóa Nginx
    if dpkg -l | grep -q nginx; then
        echo "Gỡ bỏ Nginx..."
        systemctl disable nginx || true
        apt purge -y nginx nginx-common nginx-core || true
        rm -rf /etc/nginx /var/log/nginx /var/www/html
        rm -f /etc/apt/sources.list.d/nginx.list
    fi
    
    # Xóa MongoDB
    if dpkg -l | grep -q mongodb-org; then
        echo "Gỡ bỏ MongoDB..."
        systemctl disable mongod || true
        apt purge -y mongodb-org* || true
        rm -rf /var/log/mongodb /var/lib/mongodb /etc/mongod.conf
        rm -f /etc/apt/sources.list.d/mongodb-org-*.list
        rm -f /usr/share/keyrings/mongodb-server-*.gpg
    fi
    
    # Xóa Node.js và NPM packages
    if command -v node >/dev/null 2>&1; then
        echo "Gỡ bỏ Node.js..."
        npm uninstall -g pm2 yarn || true
        apt purge -y nodejs npm || true
        rm -rf /usr/lib/node_modules
        rm -f /etc/apt/sources.list.d/nodesource.list
    fi
    
    # Xóa Postfix và OpenDKIM
    if dpkg -l | grep -q postfix; then
        echo "Gỡ bỏ Postfix và OpenDKIM..."
        systemctl disable postfix || true
        systemctl disable opendkim || true
        apt purge -y postfix postfix-* opendkim opendkim-tools || true
        rm -rf /etc/postfix /etc/opendkim
    fi
    
    # Xóa Certbot
    if command -v certbot >/dev/null 2>&1; then
        echo "Gỡ bỏ Certbot..."
        snap remove certbot || true
        rm -f /usr/bin/certbot
        rm -rf /etc/letsencrypt
    fi
    
    # Xóa Fail2ban
    if dpkg -l | grep -q fail2ban; then
        echo "Gỡ bỏ Fail2ban..."
        systemctl disable fail2ban || true
        apt purge -y fail2ban || true
        rm -rf /etc/fail2ban
    fi
    
    # Xóa các file cấu hình tùy chỉnh
    rm -f /usr/local/bin/nmpanel
    rm -rf /var/www/certbot
    
    # Cleanup apt
    apt autoremove -y || true
    apt autoclean || true
    
    echo "✅ Cleanup hoàn tất!"
}

# Hàm kiểm tra và cài đặt lại service bị lỗi
check_and_fix_service() {
    local service_name=$1
    local max_attempts=3
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        echo "🔍 Kiểm tra $service_name (lần thử $attempt/$max_attempts)..."
        
        if systemctl is-active --quiet $service_name; then
            echo "✅ $service_name đang hoạt động bình thường"
            return 0
        else
            echo "❌ $service_name không hoạt động, đang khắc phục..."
            
            case $service_name in
                "nginx")
                    # Fix nginx user issue
                    if grep -q "user nginx" /etc/nginx/nginx.conf; then
                        sed -i 's/user nginx/user www-data/' /etc/nginx/nginx.conf
                    fi
                    # Test config
                    if nginx -t; then
                        systemctl restart nginx
                    else
                        echo "Nginx config có lỗi, đang tạo lại config cơ bản..."
                        create_basic_nginx_config
                    fi
                    ;;
                "mongod")
                    # Fix MongoDB permissions
                    chown -R mongodb:mongodb /var/lib/mongodb
                    chown mongodb:mongodb /tmp/mongodb-*.sock || true
                    systemctl restart mongod
                    ;;
                *)
                    systemctl restart $service_name
                    ;;
            esac
            
            sleep 5
        fi
        
        ((attempt++))
    done
    
    echo "⚠️ Không thể khởi động $service_name sau $max_attempts lần thử"
    FAILED_COMPONENTS+=($service_name)
    return 1
}

# Tạo config Nginx cơ bản khi bị lỗi
create_basic_nginx_config() {
    cat > /etc/nginx/nginx.conf <<EOF
user www-data;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 768;
}

http {
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    
    access_log /var/log/nginx/access.log;
    error_log /var/log/nginx/error.log;
    
    gzip on;
    
    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
EOF
    nginx -t
}

# Hàm retry cho SSL certificate
retry_ssl_certificate() {
    local domain=$1
    local mail_domain=$2
    local max_attempts=3
    local attempt=1

    # Kiểm tra input parameters
    if [ -z "$domain" ] || [ -z "$mail_domain" ]; then
        echo "❌ Lỗi: Domain hoặc mail_domain không được cung cấp"
        echo "📝 Domain: '$domain'"
        echo "📝 Mail domain: '$mail_domain'"
        return 1
    fi
    
    echo "🔒 Bắt đầu lấy SSL certificate cho domain: $domain và mail: $mail_domain"
    
    while [ $attempt -le $max_attempts ]; do
        echo "🔒 Đang thử lấy SSL certificate (lần $attempt/$max_attempts)..."
        
        # Kiểm tra và tạo webroot directory
        mkdir -p /var/www/certbot
        chown -R www-data:www-data /var/www/certbot
        
        # Thử webroot method trước
        if certbot certonly --webroot -w /var/www/certbot -d ${domain} -d ${mail_domain} --agree-tos --register-unsafely-without-email --non-interactive; then
            echo "✅ Lấy SSL certificate thành công bằng webroot method"
            return 0
        fi
        
        echo "❌ Webroot method thất bại, thử standalone method..."
        systemctl stop nginx
        
        if certbot certonly --standalone -d ${domain} -d ${mail_domain} --agree-tos --register-unsafely-without-email --non-interactive; then
            echo "✅ Lấy SSL certificate thành công bằng standalone method"
            systemctl start nginx
            return 0
        fi
        
        systemctl start nginx
        echo "❌ Standalone method cũng thất bại"
        
        if [ $attempt -lt $max_attempts ]; then
            echo "⏳ Chờ 30 giây trước khi thử lại..."
            sleep 30
        fi
        
        ((attempt++))
    done
    
    echo "⚠️ Không thể lấy SSL certificate sau $max_attempts lần thử"
    echo "📝 Hướng dẫn khắc phục thủ công:"
    echo "   1. Kiểm tra DNS của domain đã trỏ đúng IP chưa"
    echo "   2. Đảm bảo port 80 và 443 không bị firewall chặn"
    echo "   3. Thử lại sau: certbot certonly --standalone -d ${domain} -d ${mail_domain}"
    
    return 1
}

# Menu cleanup và restart
show_cleanup_menu() {
    echo "======================================================="
    echo "🛠️  MENU KHẮC PHỤC LỖI"
    echo "======================================================="
    echo "1) Cleanup toàn bộ và cài lại từ đầu"
    echo "2) Chỉ cleanup các thành phần bị lỗi"
    echo "3) Khắc phục lỗi Nginx"
    echo "4) Khắc phục lỗi SSL Certificate"
    echo "5) Khắc phục lỗi MongoDB"
    echo "6) Kiểm tra trạng thái tất cả services"
    echo "7) Tiếp tục cài đặt"
    echo "0) Thoát"
    echo "======================================================="
    
    read -p "Chọn tùy chọn: " cleanup_choice
    
    case $cleanup_choice in
        1)
            echo "⚠️  CẢNH BÁO: Sẽ xóa toàn bộ cài đặt hiện tại!"
            read -p "Bạn có chắc chắn? (yes/no): " confirm
            if [[ "$confirm" == "yes" ]]; then
                cleanup_installation
                echo "🔄 Bắt đầu cài đặt lại từ đầu..."
                return 0
            fi
            ;;
        2)
            echo "🧹 Cleanup các thành phần bị lỗi..."
            for component in "${FAILED_COMPONENTS[@]}"; do
                echo "Đang cleanup $component..."
                systemctl stop $component || true
                systemctl disable $component || true
            done
            ;;
        3)
            echo "🔧 Khắc phục lỗi Nginx..."
            systemctl stop nginx || true
            create_basic_nginx_config
            check_and_fix_service "nginx"
            ;;
        4)
            read -p "Nhập domain chính: " fix_domain
            read -p "Nhập mail domain: " fix_mail_domain
            retry_ssl_certificate "$fix_domain" "$fix_mail_domain"
            ;;
        5)
            echo "🔧 Khắc phục lỗi MongoDB..."
            systemctl stop mongod || true
            chown -R mongodb:mongodb /var/lib/mongodb
            systemctl start mongod
            check_and_fix_service "mongod"
            ;;
        6)
            echo "🔍 Kiểm tra trạng thái services..."
            services=("nginx" "mongod" "postfix" "opendkim" "fail2ban")
            for service in "${services[@]}"; do
                if systemctl is-active --quiet $service; then
                    echo "✅ $service: Đang chạy"
                else
                    echo "❌ $service: Không chạy"
                fi
            done
            ;;
        7)
            echo "▶️ Tiếp tục với quá trình cài đặt..."
            return 0
            ;;
        0)
            echo "👋 Thoát script"
            exit 0
            ;;
        *)
            echo "❌ Lựa chọn không hợp lệ"
            show_cleanup_menu
            ;;
    esac
    
    echo ""
    read -p "Nhấn Enter để tiếp tục..."
    show_cleanup_menu
}

# Kiểm tra quyền root
if [ "$EUID" -ne 0 ]; then
  echo "⚠️ Vui lòng chạy script này với quyền root (sudo)."
  exit 1
fi

# Kiểm tra nếu có lỗi từ lần chạy trước
if [ -f "/tmp/vps_setup_error.flag" ]; then
    echo "🚨 Phát hiện có lỗi từ lần cài đặt trước!"
    echo "📋 Lỗi cuối cùng:"
    cat /tmp/vps_setup_error.flag
    echo ""
    show_cleanup_menu
fi

# Trap để bắt lỗi
trap 'handle_error $? $LINENO' ERR

handle_error() {
    local exit_code=$1
    local line_number=$2
    echo "❌ LỖI XẢY RA tại dòng $line_number với mã lỗi $exit_code" | tee /tmp/vps_setup_error.flag
    echo "📅 Thời gian: $(date)" >> /tmp/vps_setup_error.flag
    echo "🔧 Đang lưu tiến trình cài đặt..." >> /tmp/vps_setup_error.flag
    
    # Save installation progress
    cat > /tmp/vps_setup_progress.json <<EOF
{
    "error_line": $line_number,
    "error_code": $exit_code,
    "error_time": "$(date -u '+%Y-%m-%d %H:%M:%S')",
    "installed_components": [$(printf '"%s",' "${INSTALLED_COMPONENTS[@]}" | sed 's/,$//')],"
    "failed_components": [$(printf '"%s",' "${FAILED_COMPONENTS[@]}" | sed 's/,$//')],"
    "domain": "${DOMAIN:-}",
    "mail_domain": "${MAIL_DOMAIN:-}",
    "app_path": "${APP_PATH:-}",
    "main_js": "${MAIN_JS:-}",
    "app_port": "${APP_PORT:-}"
}
EOF
    
    echo "🔧 Đang mở menu khắc phục lỗi..."
    show_cleanup_menu
}

# Kiểm tra người dùng
CURRENT_USER=$(whoami)
echo "👤 Người dùng hiện tại: $CURRENT_USER"

# Hàm kiểm tra kết nối internet
check_internet() {
    echo "🌐 Kiểm tra kết nối internet..."
    if ! ping -c 1 google.com &> /dev/null; then
        echo "❌ Không có kết nối internet. Vui lòng kiểm tra lại."
        exit 1
    fi
    echo "✅ Kết nối internet OK"
}

# Xử lý tham số command line
case "${1:-}" in
    --cleanup|--clean)
        echo "🧹 Chế độ cleanup - Gỡ bỏ tất cả thành phần"
        cleanup_installation
        echo "✅ Cleanup hoàn tất. Có thể chạy lại script để cài đặt mới."
        exit 0
        ;;
    --fix|--repair)
        echo "🔧 Chế độ sửa lỗi"
        show_cleanup_menu
        ;;
    --help|-h)
        echo "======================================================="
        echo "🚀 VPS SETUP SCRIPT - HƯỚNG DẪN SỬ DỤNG"
        echo "======================================================="
        echo "Cách sử dụng: $0 [tùy chọn]"
        echo ""
        echo "Tùy chọn:"
        echo "  (không tham số)     Cài đặt bình thường"
        echo "  --cleanup, --clean  Gỡ bỏ toàn bộ cài đặt"
        echo "  --fix, --repair     Mở menu khắc phục lỗi"
        echo "  --help, -h          Hiển thị hướng dẫn này"
        echo ""
        echo "Ví dụ:"
        echo "  sudo bash $0                # Cài đặt bình thường"
        echo "  sudo bash $0 --cleanup      # Gỡ bỏ toàn bộ"
        echo "  sudo bash $0 --fix          # Khắc phục lỗi"
        echo ""
        echo "Lưu ý: Script cần chạy với quyền root (sudo)"
        echo "======================================================="
        exit 0
        ;;
esac

# Kiểm tra kết nối trước khi bắt đầu
check_internet

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

# Validate all required variables
validate_installation_variables() {
    echo "🔍 Kiểm tra tính hợp lệ của các biến cài đặt..."
    
    local validation_failed=false
    
    if [ -z "${DOMAIN}" ]; then
        echo "❌ Lỗi: DOMAIN không được đặt"
        validation_failed=true
    fi
    
    if [ -z "${MAIL_DOMAIN}" ]; then
        echo "❌ Lỗi: MAIL_DOMAIN không được đặt"
        validation_failed=true
    fi
    
    if [ -z "${APP_PATH}" ]; then
        echo "❌ Lỗi: APP_PATH không được đặt"
        validation_failed=true
    fi
    
    if [ -z "${MAIN_JS}" ]; then
        echo "❌ Lỗi: MAIN_JS không được đặt"
        validation_failed=true
    fi
    
    if [ -z "${APP_PORT}" ]; then
        echo "❌ Lỗi: APP_PORT không được đặt"
        validation_failed=true
    fi
    
    # Validate domain format
    if ! echo "${DOMAIN}" | grep -E '^[a-zA-Z0-9][a-zA-Z0-9-]{1,61}[a-zA-Z0-9]\.[a-zA-Z]{2,}$' >/dev/null; then
        echo "❌ Lỗi: Domain '${DOMAIN}' không hợp lệ"
        validation_failed=true
    fi
    
    # Validate port number
    if ! [[ "${APP_PORT}" =~ ^[0-9]+$ ]] || [ "${APP_PORT}" -lt 1 ] || [ "${APP_PORT}" -gt 65535 ]; then
        echo "❌ Lỗi: Port '${APP_PORT}' không hợp lệ (phải từ 1-65535)"
        validation_failed=true
    fi
    
    if [ "$validation_failed" = true ]; then
        echo "💥 Validation thất bại! Mở menu khắc phục..."
        show_cleanup_menu
    else
        echo "✅ Tất cả biến cài đặt đều hợp lệ"
    fi
}

# Thực hiện validation
validate_installation_variables

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

# NGINX - Kiểm tra và sử dụng URL hiện tại với error handling
echo "🌐 Đang cài đặt NGINX phiên bản ${NGINX_VER}..."

# Kiểm tra và xóa nginx cũ nếu có lỗi
if dpkg -l | grep -q nginx && ! nginx -t 2>/dev/null; then
    echo "⚠️ Phát hiện Nginx bị lỗi cấu hình, đang gỡ bỏ..."
    systemctl stop nginx || true
    apt purge -y nginx nginx-common nginx-core || true
    rm -rf /etc/nginx /var/log/nginx
fi

# Cài đặt Nginx
apt install -y curl gnupg2 ca-certificates lsb-release ubuntu-keyring

# Thử cài từ repository chính thức trước
nginx_installed=false

# Phương pháp 1: Repository chính thức
if ! $nginx_installed; then
    echo "📦 Thử cài Nginx từ repository chính thức..."
    curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --dearmor | tee /usr/share/keyrings/nginx-archive-keyring.gpg >/dev/null 2>&1 || \
    curl -fsSL https://packages.nginx.org/keys/nginx_signing.key | gpg --dearmor | tee /usr/share/keyrings/nginx-archive-keyring.gpg >/dev/null 2>&1
    
    if [ -f /usr/share/keyrings/nginx-archive-keyring.gpg ]; then
        ubuntu_codename=$(lsb_release -cs)
        echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/${NGINX_VER}/ubuntu ${ubuntu_codename} nginx" | tee /etc/apt/sources.list.d/nginx.list
        
        if apt update && apt install -y nginx; then
            nginx_installed=true
            echo "✅ Nginx đã được cài từ repository chính thức"
            INSTALLED_COMPONENTS+=("nginx-official")
        else
            echo "❌ Không thể cài từ repository chính thức"
            rm -f /etc/apt/sources.list.d/nginx.list
        fi
    fi
fi

# Phương pháp 2: Repository Ubuntu mặc định
if ! $nginx_installed; then
    echo "📦 Thử cài Nginx từ repository Ubuntu..."
    apt update
    if apt install -y nginx; then
        nginx_installed=true
        echo "✅ Nginx đã được cài từ repository Ubuntu"
        INSTALLED_COMPONENTS+=("nginx-ubuntu")
    else
        echo "❌ Không thể cài Nginx từ repository Ubuntu"
        FAILED_COMPONENTS+=("nginx")
    fi
fi

if ! $nginx_installed; then
    echo "💥 KHÔNG THỂ CÀI NGINX!"
    echo "🔧 Mở menu khắc phục..."
    show_cleanup_menu
fi

echo "NGINX đã được cài đặt:"
nginx -v

# Tạo user www-data nếu chưa có
if ! id -u www-data >/dev/null 2>&1; then
    useradd -r -s /bin/false www-data
fi

# Backup tệp cấu hình NGINX gốc
if [ -f /etc/nginx/nginx.conf ]; then
  cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.backup.$(date +%Y%m%d%H%M%S)
fi

# Tạo thư mục sites-available và sites-enabled nếu không tồn tại
mkdir -p /etc/nginx/sites-available
mkdir -p /etc/nginx/sites-enabled

# Tạo config Nginx tối ưu và an toàn
create_optimized_nginx_config() {
    cat > /etc/nginx/nginx.conf <<EOF
user www-data;
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

    # Rate limiting zones
    limit_req_zone \$binary_remote_addr zone=one:10m rate=1r/s;
    limit_conn_zone \$binary_remote_addr zone=addr:10m;

    # Bao gồm các cấu hình khác
    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
EOF
}

# Tạo config Nginx tối ưu
create_optimized_nginx_config

# Test config và khởi động Nginx
if nginx -t; then
    systemctl enable nginx
    systemctl restart nginx
    echo "✅ Nginx config hợp lệ và đã khởi động"
    INSTALLED_COMPONENTS+=("nginx-config")
else
    echo "❌ Nginx config có lỗi, tạo config cơ bản..."
    create_basic_nginx_config
    if nginx -t && systemctl restart nginx; then
        echo "⚠️ Đã sử dụng config cơ bản cho Nginx"
    else
        echo "💥 Không thể khởi động Nginx"
        FAILED_COMPONENTS+=("nginx-config")
        show_cleanup_menu
    fi
fi

# Certbot - Kiểm tra và cài đặt với error handling
echo "🔒 Đang cài đặt Certbot..."

certbot_installed=false

# Kiểm tra snapd
if ! command -v snap >/dev/null 2>&1; then
    echo "📦 Cài đặt snapd..."
    apt install -y snapd
    systemctl enable snapd.socket
    systemctl start snapd.socket
fi

# Thử cài Certbot qua snap
if ! $certbot_installed; then
    echo "📦 Cài đặt Certbot qua snap..."
    if snap install core && snap refresh core && snap install --classic certbot; then
        ln -sf /snap/bin/certbot /usr/bin/certbot || true
        certbot_installed=true
        echo "✅ Certbot đã được cài từ snap"
        INSTALLED_COMPONENTS+=("certbot-snap")
    else
        echo "❌ Không thể cài Certbot qua snap"
    fi
fi

# Phương pháp dự phòng: cài qua apt
if ! $certbot_installed; then
    echo "📦 Thử cài Certbot qua apt..."
    if apt install -y certbot python3-certbot-nginx; then
        certbot_installed=true
        echo "✅ Certbot đã được cài từ apt"
        INSTALLED_COMPONENTS+=("certbot-apt")
    else
        echo "❌ Không thể cài Certbot"
        FAILED_COMPONENTS+=("certbot")
    fi
fi

if ! $certbot_installed; then
    echo "💥 KHÔNG THỂ CÀI CERTBOT!"
    show_cleanup_menu
fi

# Cấu hình NGINX HTTP với improved config
echo "📝 Tạo cấu hình Nginx HTTP..."
cat > /etc/nginx/sites-available/${DOMAIN}.conf <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN} ${MAIL_DOMAIN};
    
    # Ghi log chi tiết để giúp gỡ lỗi
    access_log /var/log/nginx/${DOMAIN}.access.log detailed;
    error_log /var/log/nginx/${DOMAIN}.error.log;

    # Cấu hình cho Let's Encrypt challenge
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
        try_files \$uri =404;
    }

    # Chuyển hướng HTTP sang HTTPS (trừ acme-challenge)
    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF

# Tạo symlink để kích hoạt cấu hình
ln -sf /etc/nginx/sites-available/${DOMAIN}.conf /etc/nginx/sites-enabled/

# Tạo thư mục certbot với quyền phù hợp
mkdir -p /var/www/certbot
chown -R www-data:www-data /var/www/certbot
chmod -R 755 /var/www/certbot

# Test và reload nginx
if nginx -t; then
    systemctl reload nginx
    echo "✅ Nginx HTTP config đã được áp dụng"
else
    echo "❌ Nginx config có lỗi"
    FAILED_COMPONENTS+=("nginx-http-config")
    show_cleanup_menu
fi

# Lấy SSL từ Let's Encrypt với retry logic
echo "🔒 Đang lấy chứng chỉ SSL từ Let's Encrypt..."

# Kiểm tra variables trước khi gọi certbot
if [ -z "${DOMAIN}" ] || [ -z "${MAIL_DOMAIN}" ]; then
    echo "❌ Lỗi: Biến DOMAIN hoặc MAIL_DOMAIN không được đặt"
    echo "📝 DOMAIN: '${DOMAIN}'"
    echo "📝 MAIL_DOMAIN: '${MAIL_DOMAIN}'"
    echo "🔧 Mở menu khắc phục lỗi..."
    FAILED_COMPONENTS+=("ssl-certificate-validation")
    show_cleanup_menu
fi

if retry_ssl_certificate "${DOMAIN}" "${MAIL_DOMAIN}"; then
    echo "✅ SSL certificate đã được cấp thành công!"
    INSTALLED_COMPONENTS+=("ssl-certificate")
else
    echo "⚠️ Không thể lấy SSL certificate tự động"
    echo "📝 Hướng dẫn tạo SSL thủ công:"
    echo "   systemctl stop nginx"
    echo "   certbot certonly --standalone -d ${DOMAIN} -d ${MAIL_DOMAIN}"
    echo "   systemctl start nginx"
    echo ""
    read -p "Bấm Enter để tiếp tục (sẽ sử dụng HTTP thay vì HTTPS)..." temp
    FAILED_COMPONENTS+=("ssl-certificate")
fi

# Cấu hình HTTPS với bảo vệ IP thật
cat > /etc/nginx/sites-available/${DOMAIN}-ssl.conf <<EOF
# File cấu hình NGINX cho ${DOMAIN} (Cập nhật: $(date -u '+%Y-%m-%d'))
# Thiết lập bởi nttrung9x - @hkvn9x

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${DOMAIN};
    
    # Ghi log chi tiết cho việc gỡ lỗi
    access_log /var/log/nginx/${DOMAIN}.ssl-access.log;
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
    location ~* \.(jpg|jpeg|png|gif|ico|css|js|svg|woff|woff2|ttf|eot)$ {
        root ${APP_PATH};
        try_files /public\$uri /assets\$uri @proxy;

        # root ${APP_PATH}/public;
        # try_files \$uri \$uri/ @proxy;

        expires 30d;
        add_header Cache-Control "public, no-transform";

        # Thêm CORS cho static files
        add_header Access-Control-Allow-Origin "*" always;
        add_header Access-Control-Allow-Methods "GET, POST, OPTIONS, PUT, DELETE" always;
        add_header Access-Control-Allow-Headers "Authorization,Content-Type,Accept" always;
    }

    # Tất cả request khác chuyển đến Node.js
    location / {
        # Thiết lập proxy headers
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
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
        proxy_pass http://localh\ost:${APP_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_hea\der X-Forwarded-For \$proxy_add_x_forwarded_for;

        # Thêm CORS cho fallback
        add_header Access-Control-Allow-Origin "*" always;
        add_header Access-Control-Allow-Methods "GET, POST, OPTIONS, PUT, DELETE" always;
        add_header Access-Control-Allow-Headers "Authorization,Content-Type,Accept" always;
    }
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${MAIL_DOMAIN};

    ssl_c\ertificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letse\ncrypt/live/${DOMAIN}/privkey.pem;\
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
        add_header Content-Type text/plain;
        return 200 "Mail server for ${DOMAIN}";
    }
}
EOF

# Tạo thư mục ssl và dhparam
mkdir -p /etc/nginx/ssl
openssl dhparam -out /etc/nginx/ssl/dhparam.pem 2048

# Tạo symlink để kích hoạt cấu hình HTTPS
ln -sf /etc/nginx/sites-available/${DOMAIN}-ssl.conf /etc/nginx/sites-enabled/

# Test nginx config trước khi restart
if nginx -t; then
    systemctl restart nginx
    echo "✅ Nginx SSL config đã được áp dụng thành công"
    INSTALLED_COMPONENTS+=("nginx-ssl-config")
else
    echo "❌ Nginx SSL config có lỗi, đang khắc phục..."
    # Xóa SSL config và chỉ giữ HTTP
    rm -f /etc/nginx/sites-enabled/${DOMAIN}-ssl.conf
    if nginx -t && systemctl restart nginx; then
        echo "⚠️ Đã fallback về HTTP, SSL config bị lỗi"
        FAILED_COMPONENTS+=("nginx-ssl-config")
    else
        echo "💥 Không thể khởi động Nginx"
        FAILED_COMPONENTS+=("nginx")
        show_cleanup_menu
    fi
fi

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

# Tạo user email 'no-reply' với password random để gửi mail SSL
echo "📧 Đang tạo user email 'no-reply' cho việc gửi mail qua Node.js..."

# Tạo password random 12 ký tự
NOREPLY_PASSWORD=$(openssl rand -base64 12 | tr -d "=+/" | cut -c1-12)
NOREPLY_EMAIL="no-reply@${DOMAIN}"

# Tạo user system cho no-reply
useradd -m -s /bin/bash -c "No Reply Email User" noreply || echo "User noreply đã tồn tại"

# Cài đặt dovecot để xử lý IMAP/POP3 cho user email
echo "📧 Cài đặt Dovecot cho IMAP/POP3..."
DEBIAN_FRONTEND=noninteractive apt install -y dovecot-core dovecot-imapd dovecot-pop3d

# Cấu hình Postfix để hỗ trợ virtual users
postconf -e "virtual_mailbox_domains = ${DOMAIN}"
postconf -e "virtual_mailbox_base = /var/mail/vmail"
postconf -e "virtual_mailbox_maps = hash:/etc/postfix/vmailbox"
postconf -e "virtual_minimum_uid = 1000"

# Lấy UID và GID của vmail user
VMAIL_UID=$(id -u vmail 2>/dev/null || echo "5000")
VMAIL_GID=$(id -g vmail 2>/dev/null || echo "5000")

postconf -e "virtual_uid_maps = static:${VMAIL_UID}"
postconf -e "virtual_gid_maps = static:${VMAIL_GID}"
postconf -e "virtual_alias_maps = hash:/etc/postfix/virtual"

echo "📋 Postfix virtual user config: UID=${VMAIL_UID}, GID=${VMAIL_GID}"

# Tạo group và user vmail cho virtual mailboxes
# Tạo group vmail trước
if ! getent group vmail >/dev/null 2>&1; then
    groupadd -g 5000 vmail
    echo "✅ Đã tạo group vmail với GID 5000"
else
    echo "ℹ️ Group vmail đã tồn tại"
fi

# Tạo user vmail
if ! getent passwd vmail >/dev/null 2>&1; then
    useradd -u 5000 -g vmail -s /bin/false -d /var/mail/vmail -m vmail
    echo "✅ Đã tạo user vmail với UID 5000"
else
    echo "ℹ️ User vmail đã tồn tại"
    # Đảm bảo user vmail có group đúng
    usermod -g vmail vmail 2>/dev/null || true
fi

# Tạo thư mục mail với proper ownership
mkdir -p /var/mail/vmail/${DOMAIN}/no-reply

# Kiểm tra và tạo ownership
if getent passwd vmail >/dev/null 2>&1 && getent group vmail >/dev/null 2>&1; then
    chown -R vmail:vmail /var/mail/vmail
    chmod -R 755 /var/mail/vmail
    echo "✅ Đã thiết lập ownership cho thư mục mail"
else
    echo "❌ Lỗi: User hoặc group vmail không tồn tại"
    echo "📝 Tạo user/group vmail thủ công..."
    # Fallback: tạo với www-data nếu vmail thất bại
    chown -R www-data:www-data /var/mail/vmail 2>/dev/null || true
    echo "⚠️ Đã fallback sang www-data ownership"
fi

# Cấu hình virtual mailbox
cat > /etc/postfix/vmailbox <<EOF
${NOREPLY_EMAIL} ${DOMAIN}/no-reply/
EOF

# Cấu hình virtual aliases
cat > /etc/postfix/virtual <<EOF
${NOREPLY_EMAIL} ${NOREPLY_EMAIL}
EOF

# Build hash tables
postmap /etc/postfix/vmailbox
postmap /etc/postfix/virtual

# Cấu hình Dovecot
# Lấy UID và GID của vmail user cho Dovecot
VMAIL_UID_DOVECOT=$(id -u vmail 2>/dev/null || echo "5000")
VMAIL_GID_DOVECOT=$(id -g vmail 2>/dev/null || echo "5000")

cat > /etc/dovecot/conf.d/10-mail.conf <<EOF
mail_location = maildir:/var/mail/vmail/%d/%n
mail_privileged_group = vmail
mail_uid = ${VMAIL_UID_DOVECOT}
mail_gid = ${VMAIL_GID_DOVECOT}
first_valid_uid = ${VMAIL_UID_DOVECOT}
last_valid_uid = ${VMAIL_UID_DOVECOT}
first_valid_gid = ${VMAIL_GID_DOVECOT}
last_valid_gid = ${VMAIL_GID_DOVECOT}
EOF

echo "📋 Dovecot config: UID=${VMAIL_UID_DOVECOT}, GID=${VMAIL_GID_DOVECOT}"

cat > /etc/dovecot/conf.d/10-auth.conf <<EOF
disable_plaintext_auth = no
auth_mechanisms = plain login
!include auth-passwdfile.conf.ext
EOF

# Tạo file auth cho user no-reply
cat > /etc/dovecot/conf.d/auth-passwdfile.conf.ext <<EOF
passdb {
  driver = passwd-file
  args = scheme=CRYPT username_format=%u /etc/dovecot/users
}

userdb {
  driver = passwd-file
  args = username_format=%u /etc/dovecot/users
  default_fields = uid=${VMAIL_UID_DOVECOT} gid=${VMAIL_GID_DOVECOT} home=/var/mail/vmail/%d/%n
}
EOF

# Tạo password hash cho no-reply user
NOREPLY_HASH=$(doveadm pw -s CRYPT -p "${NOREPLY_PASSWORD}")

# Tạo file users cho dovecot
cat > /etc/dovecot/users <<EOF
${NOREPLY_EMAIL}:${NOREPLY_HASH}:${VMAIL_UID_DOVECOT}:${VMAIL_GID_DOVECOT}::/var/mail/vmail/${DOMAIN}/no-reply::
EOF

chmod 600 /etc/dovecot/users

# Cấu hình SSL cho Dovecot (sử dụng chung cert với domain)
cat > /etc/dovecot/conf.d/10-ssl.conf <<EOF
ssl = yes
ssl_cert = </etc/letsencrypt/live/${DOMAIN}/fullchain.pem
ssl_key = </etc/letsencrypt/live/${DOMAIN}/privkey.pem
ssl_prefer_server_ciphers = yes
ssl_protocols = !SSLv3 !TLSv1 !TLSv1.1
EOF

# Cấu hình Dovecot listener
cat > /etc/dovecot/conf.d/10-master.conf <<EOF
service imap-login {
  inet_listener imap {
    port = 143
  }
  inet_listener imaps {
    port = 993
    ssl = yes
  }
}

service pop3-login {
  inet_listener pop3 {
    port = 110
  }
  inet_listener pop3s {
    port = 995
    ssl = yes
  }
}

service lmtp {
  unix_listener lmtp {
    mode = 0600
    user = postfix
    group = postfix
  }
}

service auth {
  unix_listener auth-userdb {
    mode = 0600
    user = vmail
    group = vmail
  }
  
  unix_listener /var/spool/postfix/private/auth {
    mode = 0666
    user = postfix
    group = postfix
  }
}
EOF

# Khởi động lại Dovecot với error handling
echo "🔄 Khởi động lại Dovecot..."
systemctl enable dovecot
if systemctl restart dovecot; then
    echo "✅ Dovecot đã khởi động thành công"
    INSTALLED_COMPONENTS+=("dovecot")
else
    echo "❌ Lỗi khởi động Dovecot"
    FAILED_COMPONENTS+=("dovecot")
    # Thử khởi động lại với debug
    echo "📝 Chi tiết lỗi Dovecot:"
    systemctl status dovecot --no-pager || true
fi

# Khởi động lại Postfix với cấu hình mới
echo "🔄 Khởi động lại Postfix..."
if systemctl restart postfix; then
    echo "✅ Postfix đã khởi động thành công"
    INSTALLED_COMPONENTS+=("postfix-virtual")
else
    echo "❌ Lỗi khởi động Postfix"
    FAILED_COMPONENTS+=("postfix-virtual")
    # Thử khởi động lại với debug
    echo "📝 Chi tiết lỗi Postfix:"
    systemctl status postfix --no-pager || true
fi

# Tạo file config cho Node.js để sử dụng email
echo "📧 Tạo cấu hình email cho Node.js..."
if cat > ${APP_PATH}/email-config.json <<EOF
{
  "email": {
    "service": "custom",
    "host": "${MAIL_DOMAIN}",
    "port": 587,
    "secure": false,
    "auth": {
      "user": "${NOREPLY_EMAIL}",
      "pass": "${NOREPLY_PASSWORD}"
    },
    "tls": {
      "rejectUnauthorized": false
    }
  },
  "imapConfig": {
    "host": "${MAIL_DOMAIN}",
    "port": 993,
    "secure": true,
    "auth": {
      "user": "${NOREPLY_EMAIL}",
      "pass": "${NOREPLY_PASSWORD}"
    },
    "tls": {
      "rejectUnauthorized": false
    }
  }
}
EOF
then
    echo "✅ Đã tạo email-config.json"
    INSTALLED_COMPONENTS+=("email-config")
else
    echo "❌ Lỗi tạo email-config.json"
    FAILED_COMPONENTS+=("email-config")
fi

# Tạo file demo Node.js để test gửi email
echo "📧 Tạo email test script..."
if cat > ${APP_PATH}/email-test.js <<EOF
const nodemailer = require('nodemailer');
const fs = require('fs');

// Đọc config email
const emailConfig = JSON.parse(fs.readFileSync('email-config.json', 'utf8'));

// Tạo transporter
const transporter = nodemailer.createTransporter(emailConfig.email);

// Function test gửi email
async function testSendEmail() {
    try {
        // Verify connection
        await transporter.verify();
        console.log('✅ Kết nối email server thành công!');
        
        // Gửi email test
        const info = await transporter.sendMail({
            from: '"${DOMAIN} System" <${NOREPLY_EMAIL}>',
            to: 'test@example.com', // Thay đổi địa chỉ email test
            subject: 'Test Email từ ${DOMAIN}',
            text: 'Đây là email test từ hệ thống ${DOMAIN}',
            html: \`
                <h2>✅ Email Test Thành Công!</h2>
                <p>Hệ thống email của <strong>${DOMAIN}</strong> đã hoạt động bình thường.</p>
                <p><strong>Thông tin:</strong></p>
                <ul>
                    <li>Email gửi: ${NOREPLY_EMAIL}</li>
                    <li>Mail server: ${MAIL_DOMAIN}</li>
                    <li>Thời gian: \${new Date().toLocaleString('vi-VN', {timeZone: 'Asia/Ho_Chi_Minh'})}</li>
                </ul>
                <hr>
                <p><small>Email này được gửi tự động từ hệ thống.</small></p>
            \`
        });
        
        console.log('📧 Email đã được gửi:', info.messageId);
        console.log('📝 Chi tiết:', info);
        
    } catch (error) {
        console.error('❌ Lỗi gửi email:', error);
    }
}

// Export để sử dụng trong các file khác
module.exports = {
    transporter,
    testSendEmail,
    emailConfig
};

// Chạy test nếu file này được execute trực tiếp
if (require.main === module) {
    testSendEmail();
}
EOF
then
    echo "✅ Đã tạo email-test.js"
    INSTALLED_COMPONENTS+=("email-test-script")
else
    echo "❌ Lỗi tạo email-test.js"
    FAILED_COMPONENTS+=("email-test-script")
fi

# Thêm nodemailer vào package.json dependencies
# Thêm nodemailer vào package.json dependencies
if [ -f "${APP_PATH}/package.json" ]; then
    echo "📦 Cập nhật package.json..."
    if node -e "
    const fs = require('fs');
    const pkg = JSON.parse(fs.readFileSync('${APP_PATH}/package.json', 'utf8'));
    pkg.dependencies = pkg.dependencies || {};
    pkg.dependencies['nodemailer'] = '^6.9.7';
    pkg.scripts = pkg.scripts || {};
    pkg.scripts['test-email'] = 'node email-test.js';
    fs.writeFileSync('${APP_PATH}/package.json', JSON.stringify(pkg, null, 2));
    " 2>/dev/null; then
        echo "✅ Đã cập nhật package.json"
    else
        echo "❌ Không thể cập nhật package.json tự động"
        FAILED_COMPONENTS+=("package-json-update")
    fi
else
    echo "⚠️ Không tìm thấy package.json"
fi

# Cài đặt nodemailer
echo "📦 Cài đặt nodemailer..."
cd ${APP_PATH}
if npm install nodemailer --save; then
    echo "✅ Đã cài đặt nodemailer thành công"
    INSTALLED_COMPONENTS+=("nodemailer")
else
    echo "❌ Lỗi cài đặt nodemailer"
    FAILED_COMPONENTS+=("nodemailer")
fi

echo "✅ User email 'no-reply' đã được tạo thành công!"
echo "📧 Email: ${NOREPLY_EMAIL}"
echo "🔐 Password: ${NOREPLY_PASSWORD}"
echo "📁 Config file: ${APP_PATH}/email-config.json"
echo "🧪 Test file: ${APP_PATH}/email-test.js"
echo ""
echo "💡 Hướng dẫn sử dụng:"
echo "   1. Chạy test: cd ${APP_PATH} && node email-test.js"
echo "   2. Sử dụng trong code: const emailConfig = require('./email-config.json')"
echo "   3. SMTP: ${MAIL_DOMAIN}:587 (STARTTLS)"
echo "   4. IMAP: ${MAIL_DOMAIN}:993 (SSL/TLS)"

INSTALLED_COMPONENTS+=("email-user-noreply")

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

# Tạo thư mục cấu hình nmpanel
echo "Tạo thư mục cấu hình nmpanel..."
mkdir -p /var/lib/nmpanel

# Tạo file cấu hình server
echo "Tạo file cấu hình server..."
cat > /var/lib/nmpanel/server-config.json <<EOF
{
    "domain": "${DOMAIN}",
    "mail_domain": "${MAIL_DOMAIN}",
    "app_path": "${APP_PATH}",
    "main_js": "${MAIN_JS}",
    "app_port": ${APP_PORT},
    "install_date": "$(date -u '+%Y-%m-%d %H:%M:%S')",
    "version": "1.0.0"
}
EOF

# Cài đặt nmpanel script từ file riêng biệt
echo "Cài đặt nmpanel management script..."
NMPANEL_SCRIPT_PATH="${SCRIPT_DIR_NMPANEL}/nmpanel.sh"
NMPANEL_RESTART_SCRIPT_PATH="${SCRIPT_DIR_NMPANEL}/nmpanel-restart.sh"

echo "SCRIPT_DIR_NMPANEL: $SCRIPT_DIR_NMPANEL"
echo "NMPANEL_SCRIPT_PATH: $NMPANEL_SCRIPT_PATH"
echo "NMPANEL_RESTART_SCRIPT_PATH: $NMPANEL_RESTART_SCRIPT_PATH"

# Biến chứa URL GitHub (dạng raw)
FILE_URL="https://raw.githubusercontent.com/<username>/<repo>/<branch>/<path>/target_script.sh"
DEST_PATH="/usr/local/bin/target_script.sh"
curl -fsSL "$FILE_URL" -o /tmp/target_script.sh

if [ -f "$NMPANEL_SCRIPT_PATH" ]; then
    echo "Tìm thấy nmpanel.sh, đang cài đặt..."
    cp "$NMPANEL_SCRIPT_PATH" /usr/local/bin/nmpanel
    chmod +x /usr/local/bin/nmpanel
    echo "✅ Đã cài đặt nmpanel script từ file riêng biệt"
else
    echo "⚠️ Không tìm thấy nmpanel.sh"
fi

if [ -f "$NMPANEL_RESTART_SCRIPT_PATH" ]; then
    echo "Tìm thấy nmpanel-restart.sh, đang cài đặt..."
    cp "$NMPANEL_RESTART_SCRIPT_PATH" /usr/local/bin/nmpanel-restart
    chmod +x /usr/local/bin/nmpanel-restart
    echo "✅ Đã cài đặt nmpanel-restart script từ file riêng biệt"
else
    echo "⚠️ Không tìm thấy nmpanel-restart.sh"
fi

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
- RAM: ${TOTA
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "SCRIPT_DIR: $SCRIPT_DIR"
L_RAM_GB}GB
- Disk: $(${SCRIPT_DIR}/- Node.js: $(node -v)
- NPM: $(npm -v)
- ${SCRIPT_DIR}/7017)
- NGINX: $(ng
echo "NMPANEL_SCRIPT_PATH: $NMPANEL_SCRIPT_PATH"
echo "NMPANEL_RESTART_SCRIPT_PATH: $NMPANEL_RESTART_SCRIPT_PATH"inx -v 2>&1)
- PM2: $(pm2 --version)

APPLICATION:
- Path: ${APP_PATH}
- Main: ${MAIN_JS}
- Dsudo omain: https://${DOMAIN}
- Port: ${APP_PORT}
- PM2 insudo stances: max (sử dụng tất cả ${CPU_CORES} cores)
- PM2 max_memory: ${MAX_MEMORY}

USEFUL COMMANDS:
- Quản lý VPS: nmpanel
- Restart NGINX: systemctl restart nginx
- View NGINX logs: tail -f /var/log/nginx/${DOMAIN}.ssl-access.log
- Restart app: csudo d ${APP_PATH} && pm2 restart all
- View app logs: cd ${APP_PATH} && psudo m2 logs
- MongoDB shell: mongosh
EOF

# Hoàn tất với báo cáo chi tiết
echo -e "\n✅ QUÁ TRÌNH CÀI ĐẶT HOÀN TẤT! ($(date -u '+%Y-%m-%d %H:%M:%S'))"

# Xóa flag lỗi nếu có
rm -f /tmp/vps_setup_error.flag

echo "======================================================="
echo "📊 BÁO CÁO CÀI ĐẶT"
echo "======================================================="

# Kiểm tra các thành phần đã cài thành công
echo "✅ CÁC THÀNH PHẦN ĐÃ CÀI THÀNH CÔNG:"
for component in "${INSTALLED_COMPONENTS[@]}"; do
    echo "   ✓ $component"
done

# Báo cáo thành phần thất bại (nếu có)
if [ ${#FAILED_COMPONENTS[@]} -gt 0 ]; then
    echo -e "\n⚠️ CÁC THÀNH PHẦN CÓ VẤN ĐỀ:"
    for component in "${FAILED_COMPONENTS[@]}"; do
        echo "   ⚠ $component"
    done
    echo ""
    echo "💡 Bạn có thể chạy lại script và chọn 'Khắc phục lỗi' để sửa các vấn đề này"
fi

# Kiểm tra trạng thái services
echo -e "\n🔍 TRẠNG THÁI CÁC DỊCH VỤ:"
services=("nginx" "mongod" "postfix" "opendkim" "fail2ban")
all_services_ok=true

for service in "${services[@]}"; do
    if systemctl is-active --quiet $service 2>/dev/null; then
        echo "   ✅ $service: Đang hoạt động"
    else
        echo "   ❌ $service: Không hoạt động"
        all_services_ok=false
    fi
done

# Hiển thị thông tin truy cập
echo -e "\n🌐 THÔNG TIN TRUY  APPCẬP:"
if [ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]; then
    echo "   🔒 Website HTTPS: https://${DOMAIN}"
    echo "   📧 Mail domain: https://${MAIL_DOMAIN}"
else
    echo "   🌐 Website HTTP: http://${DOMAIN}"
    echo "   ⚠️ SSL chưa được cài đặt - chỉ sử dụng HTTP"
fi

echo "   📂 Đường dẫn ứng dụng: ${APP_PATH}/${MAIN_JS}"
echo "   🚀 PM2 Status: $

SSL Let's Encrypt:
/etc/letsencrypt/live/${DOMAIN}/fullchain.pem

+ Lung Tung:
- Gõ 'nmpanel' để mở menu quản lý hệ thống
- Khởi động lại nginx: sudo systemctl restart nginx
- Xem PM2: cd ${APP_PATH} && sudo pm2 status
- Xem logs: cd ${APP_PATH} && sudo pm2 logs


+ Email No-Reply:
- User email 'no-reply' đã được tạo thành công!
- Email: ${NOREPLY_EMAIL}
- Password: ${NOREPLY_PASSWORD}
- Config file: ${APP_PATH}/email-config.json
- Test file: ${APP_PATH}/email-test.js

+ Hướng dẫn sử dụng Email:
1. Chạy test: cd ${APP_PATH} && node email-test.js
2. Sử dụng trong code: const emailConfig = require('./email-config.json')
3. SMTP: ${MAIL_DOMAIN}:587 (STARTTLS)
4. IMAP: ${MAIL_DOMAIN}:993 (SSL/TLS)

+ DNS RECORDS:
   A      ${DOMAIN}         → ${SERVER_IP}"
   A      ${MAIL_DOMAIN}    → ${SERVER_IP}"
   MX     ${DOMAIN}         → mail.${DOMAIN} (priority 10)"
   TXT    ${DOMAIN}         → v=spf1 mx a ~all"
   TXT    _dmarc.${DOMAIN}  → v=DMARC1; p=none"
   TXT    mail._domainkey.${DOMAIN} → $(cat /etc/opendkim/keys/${DOMAIN}/mail.txt | grep -v '^;' | tr -d '\n\t' | sed 's/mail._domainkey[^"]*"//')"
(cd ${APP_PATH} && pm2 status 2>/dev/null | grep -c online || echo "0") ứng dụng đang chạy"

# Thông tin hệ thống
echo -e "\n💻 THÔNG TIN HỆ THỐNG:"
echo "   🖥️ RAM: ${TOTAL_RAM_GB}GB"
echo "   🧠 CPU: ${CPU_CORES} cores"
echo "   📦 PM2 instances: ${PM2_INSTANCES}"
echo "   💾 PM2 max memory: ${MAX_MEMORY}"

echo -e "\n📋 FILES VÀ LOGS QUAN TRỌNG:"
echo "   📝 Log cài đặt: $LOG_FILE"
echo "   📄 Thông tin chi tiết: ${APP_PATH}/server-info.txt"
echo "   🔧 Nginx config: /etc/nginx/sites-available/${DOMAIN}*.conf"
echo "   📊 Nginx logs: /var/log/nginx/${DOMAIN}*.log"

echo -e "\n💡 HƯỚNG DẪN SỬ DỤNG:"
echo "   🎛️ Gõ 'nmpanel' để mở menu quản lý hệ thống"
echo "   🔄 Khởi động lại: systemctl restart nginx"
echo "   📊 Xem PM2: cd ${APP_PATH} && pm2 status"
echo "   🔍 Xem logs: cd ${APP_PATH} && pm2 logs"
echo "   🗄️ MongoDB shell: mongosh"
echo "   🔗 Shortcut: ./${APP_DIR_NAME}"

if ! $all_services_ok || [ ${#FAILED_COMPONENTS[@]} -gt 0 ]; then
    echo -e "\n🔧 KHẮC PHỤC VẤN ĐỀ:"
    echo "   Nếu gặp vấn đề, hãy chạy lại script này và chọn menu khắc phục lỗi"
    echo "   Hoặc chạy: bash $0 --fix"
fi

echo -e "\n🎯 DNS RECORDS CẦN THIẾT:"
SERVER_IP=$(curl -s ifconfig.me || curl -s icanhazip.com || curl -s ipinfo.io/ip || echo "YOUR_SERVER_IP")
echo "   A      ${DOMAIN}         → ${SERVER_IP}"
echo "   A      ${MAIL_DOMAIN}    → ${SERVER_IP}"
echo "   MX     ${DOMAIN}         → mail.${DOMAIN} (priority 10)"
echo "   TXT    ${DOMAIN}         → v=spf1 mx a ~all"
echo "   TXT    _dmarc.${DOMAIN}  → v=DMARC1; p=none"
if [ -f "/etc/opendkim/keys/${DOMAIN}/mail.txt" ]; then
    echo "   TXT    mail._domainkey.${DOMAIN} → $(cat /etc/opendkim/keys/${DOMAIN}/mail.txt | grep -v '^;' | tr -d '\n\t' | sed 's/mail._domainkey[^"]*"//')"
fi

echo "✅ User email 'no-reply' đã được tạo thành công!"
echo "📧 Email: ${NOREPLY_EMAIL}"
echo "🔐 Password: ${NOREPLY_PASSWORD}"
echo "📁 Config file: ${APP_PATH}/email-config.json"
echo "🧪 Test file: ${APP_PATH}/email-test.js"
echo ""
echo "💡 Hướng dẫn sử dụng:"
echo "   1. Chạy test: cd ${APP_PATH} && node email-test.js"
echo "   2. Sử dụng trong code: const emailConfig = require('./email-config.json')"
echo "   3. SMTP: ${MAIL_DOMAIN}:587 (STARTTLS)"
echo "   4. IMAP: ${MAIL_DOMAIN}:993 (SSL/TLS)"

echo -e "\n${GREEN}======================================================="
echo "🎉 CẢM ỚN BẠN ĐÃ SỬ DỤNG SCRIPT CỦA NMPANEL !"
echo "🔗 GitHub: https://github.com/nttrung9x/nmpanel"
echo "📧 Support: Contact via GitHub issues"
echo "+ Gọi NmPanel để quản lý hệ thống Node.js của bạn một cách dễ dàng!"
echo "- Câu lệnh: nmpanel"
echo "- Câu lệnh khởi động lại: nmpanel-restart"
echo "=======================================================${NC}"

echo -e "\n🎯 QUICK COMMANDS:"
echo "   nmpanel           - Mở menu quản lý"
e
set-timezone Asia/Ho_Chi_Minh >/dev/null 2>&1 || true
