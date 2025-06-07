#!/bin/bash

# ===========================
# NmPanel Restart Script
# Quản lý VPS Node.js - MongoDB một cách dễ dàng
# Tác giả: nttrung9x - FB/hkvn9x - 0372.972.971
# Ngày tạo: 2025-06-06
# Phiên bản: 2.1
# ===========================

SERVER_CONFIG_FILE="/var/lib/nmpanel/server-config.json"
if [ -f "$SERVER_CONFIG_FILE" ]; then
    DOMAIN=$(grep '"domain"' $SERVER_CONFIG_FILE | cut -d'"' -f4)
    MAIL_DOMAIN=$(grep '"mail_domain"' $SERVER_CONFIG_FILE | cut -d'"' -f4)
    APP_PATH=$(grep '"app_path"' $SERVER_CONFIG_FILE | cut -d'"' -f4)
    MAIN_JS=$(grep '"main_js"' $SERVER_CONFIG_FILE | cut -d'"' -f4)
    APP_PORT=$(grep '"app_port"' $SERVER_CONFIG_FILE | cut -d'"' -f4)
fi

echo "🔄 Khởi động lại services: restart nginx mongod postfix opendkim fail2ban"
systemctl restart nginx mongod postfix opendkim fail2ban
cd ${APP_PATH} && pm2 restart all
echo "✅ Đã khởi động lại tất cả!"
