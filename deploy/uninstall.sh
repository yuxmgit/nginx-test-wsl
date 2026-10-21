#!/bin/bash
#
# 卸载 / 完全清理脚本
# 用法：bash deploy/uninstall.sh
#

set -u

INSTALL_DIR="${INSTALL_DIR:-$HOME/nginx-project}"

log()  { echo -e "\n\033[1;36m==> $*\033[0m"; }
warn() { echo -e "\033[1;33m[警告] $*\033[0m"; }

log "停止并禁用后端服务"
for N in 1 2; do
    if systemctl list-unit-files 2>/dev/null | grep -q "api-server$N.service"; then
        sudo systemctl stop "api-server$N" 2>/dev/null
        sudo systemctl disable "api-server$N" 2>/dev/null
        sudo rm -f "/etc/systemd/system/api-server$N.service"
        echo "    已移除 api-server$N.service"
    fi
done

sudo systemctl daemon-reload
sudo systemctl reset-failed 2>/dev/null || true

log "清理 Nginx 站点配置"
if [ -L /etc/nginx/sites-enabled/nginx-app ]; then
    sudo rm -f /etc/nginx/sites-enabled/nginx-app
fi
if [ -f /etc/nginx/sites-available/nginx-app ]; then
    sudo rm -f /etc/nginx/sites-available/nginx-app
fi

# 清理 nginx.conf 里插入的 upstream 块
if grep -q "upstream api_backend" /etc/nginx/nginx.conf 2>/dev/null; then
    warn "检测到 /etc/nginx/nginx.conf 中有手动插入的 upstream 块"
    read -rp "    是否一并移除？(y/N) " ans
    if [ "${ans:-N}" = "y" ]; then
        sudo cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak.$(date +%Y%m%d)
        sudo sed -i '/upstream api_backend {/,/^    }$/d' /etc/nginx/nginx.conf
        echo "    已移除（备份在 nginx.conf.bak.$(date +%Y%m%d)）"
    fi
fi

sudo nginx -t && sudo systemctl reload nginx 2>/dev/null || true

log "清理项目目录"
if [ -d "$INSTALL_DIR" ]; then
    warn "即将删除 $INSTALL_DIR"
    read -rp "    确认删除？(yes 确认) " ans
    if [ "$ans" = "yes" ]; then
        rm -rf "$INSTALL_DIR"
        echo "    已删除"
    else
        echo "    已跳过"
    fi
else
    echo "    目录不存在，跳过"
fi

log "清理完成"
echo ""
echo "如需彻底卸载 Nginx：sudo apt purge nginx"
echo "如需清理 systemd 残留：sudo systemctl daemon-reload"
