#!/bin/bash
#
# WSL Ubuntu 一键部署脚本
# 用途：把 Nginx + 两个 Node 后端部署到 WSL Ubuntu，并配置为 systemd 托管
# 用法：
#   bash deploy/deploy.sh
#
# 可选环境变量：
#   PROJECT_SRC  项目在 Windows 侧的路径（默认 /mnt/i/练习/nginx）
#   INSTALL_DIR  安装到 Ubuntu 的位置（默认 ~/nginx-project）
#   RUN_USER     运行服务的用户（默认当前用户）

set -e   # 任何命令失败立即退出，避免半成品状态
set -u   # 使用未定义变量时报错

# ============ 配置区 =============
PROJECT_SRC="${PROJECT_SRC:-/mnt/i/练习/nginx}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/nginx-project}"
RUN_USER="${RUN_USER:-$(whoami)}"
NODE_BIN="$(command -v node || echo /usr/bin/node)"
# ===================================

log()  { echo -e "\n\033[1;36m==> $*\033[0m"; }
warn() { echo -e "\033[1;33m[警告] $*\033[0m"; }
die()  { echo -e "\033[1;31m[错误] $*\033[0m"; exit 1; }

# ---------- 0. 环境检查 ----------
log "步骤 0/7  环境检查"

if [ "$(uname -s)" != "Linux" ]; then
    die "此脚本只能在 Linux / WSL Ubuntu 里运行，当前系统是 $(uname -s)"
fi

if grep -qi microsoft /proc/version 2>/dev/null; then
    echo "    检测到 WSL 环境"
else
    warn "当前不是 WSL，脚本仍可运行（非 WSL 环境下也能部署）"
fi

# 检查 systemd 是否启用
if [ "$(ps -p 1 -o comm= 2>/dev/null)" = "systemd" ]; then
    echo "    systemd 已启用"
else
    warn "systemd 未启用，将改用 nohup 方式启动服务"
    USE_SYSTEMD=0
fi
USE_SYSTEMD="${USE_SYSTEMD:-1}"

[ -d "$PROJECT_SRC" ] || die "找不到项目源目录：$PROJECT_SRC
请检查路径，或先执行：
  ls /mnt/
确认 WSL 里的挂载点。Windows 的 I 盘通常挂载在 /mnt/i"

[ -f "$PROJECT_SRC/backend/api-server1.js" ] || die "项目结构不对，缺少 backend/api-server1.js"

command -v curl >/dev/null || { warn "未安装 curl，正在安装"; sudo apt update && sudo apt install -y curl; }

if ! command -v node >/dev/null; then
    die "未安装 Node.js。请先执行：
  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/master/install.sh | bash
  source ~/.bashrc && nvm install 22"
fi
echo "    Node 版本：$(node -v)"
echo "    npm 版本：$(npm -v)"

if ! command -v nginx >/dev/null; then
    log "安装 Nginx"
    sudo apt update
    sudo apt install -y nginx
fi
echo "    Nginx 版本：$(nginx -v 2>&1)"

# ---------- 1. 拷贝项目 ----------
log "步骤 1/7  拷贝项目到 Linux 文件系统"

if [ -d "$INSTALL_DIR" ]; then
    warn "目标目录已存在：$INSTALL_DIR"
    read -rp "    是否覆盖并重新部署？(y/N) " ans
    if [ "${ans:-N}" != "y" ]; then
        die "用户取消"
    fi
    sudo systemctl stop api-server1 api-server2 2>/dev/null || true
    rm -rf "$INSTALL_DIR"
fi

mkdir -p "$INSTALL_DIR"
# 注意：不要在 /mnt/c 或 /mnt/i 下直接跑 Node 项目，跨系统 IO 极慢
cp -a "$PROJECT_SRC/backend"  "$INSTALL_DIR/"
cp -a "$PROJECT_SRC/frontend" "$INSTALL_DIR/"
mkdir -p "$INSTALL_DIR/logs"

# 手动部署没有 Jenkins 写版本信息，这里用模板兜底，保证前端面板不 404
if [ ! -f "$INSTALL_DIR/frontend/version.json" ]; then
    if [ -f "$INSTALL_DIR/frontend/version.json.template" ]; then
        cp "$INSTALL_DIR/frontend/version.json.template" "$INSTALL_DIR/frontend/version.json"
        echo "    已用模板生成 frontend/version.json（手动部署无构建信息）"
    fi
fi

echo "    项目已安装到 $INSTALL_DIR"
ls -la "$INSTALL_DIR"

# ---------- 2. 权限 ----------
log "步骤 2/7  设置权限"
chmod +r "$INSTALL_DIR"/backend/*.js
chmod 755 "$INSTALL_DIR"
echo "    完成"

# ---------- 3. Nginx 配置 ----------
log "步骤 3/7  配置 Nginx"

NGINX_SITE="/etc/nginx/sites-available/nginx-app"
NGINX_LINK="/etc/nginx/sites-enabled/nginx-app"

sudo cp /etc/nginx/sites-available/default /etc/nginx/sites-available/nginx-app.bak 2>/dev/null || true

# upstream 块要放在 http {} 内；Ubuntu 也可能已通过 conf.d 或 sites-enabled 定义
UPSTREAM_PATTERN='^[[:space:]]*upstream[[:space:]]+api_backend[[:space:]]*\{'
NGINX_CONFIG_FILES=(/etc/nginx/nginx.conf /etc/nginx/conf.d/*.conf /etc/nginx/sites-enabled/*)
UPSTREAM_COUNT=$(grep -hE "$UPSTREAM_PATTERN" "${NGINX_CONFIG_FILES[@]}" 2>/dev/null | wc -l)

if [ "$UPSTREAM_COUNT" -gt 1 ]; then
    die "检测到 $UPSTREAM_COUNT 个 api_backend upstream 定义，请先在 /etc/nginx 配置中保留一份"
elif [ "$UPSTREAM_COUNT" -eq 0 ]; then
    echo "    向 /etc/nginx/nginx.conf 插入 upstream 块"
    sudo sed -i '/^http {/a\\n    upstream api_backend {\n        server 127.0.0.1:4001;\n        server 127.0.0.1:4002;\n    }\n' /etc/nginx/nginx.conf
else
    echo "    已存在 api_backend upstream，跳过插入"
fi

sudo tee "$NGINX_SITE" > /dev/null << EOF
server {
    listen 80;
    listen [::]:80;
    server_name localhost;

    # 前端静态文件
    location / {
        root $INSTALL_DIR/frontend;
        index index.html;
        try_files \$uri \$uri/ /index.html;
    }

    # 后端 API 负载均衡
    location /api/ {
        proxy_pass http://api_backend;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    # 静态资源缓存
    location ~* \.(css|js|png|jpg|jpeg|gif|ico|svg|woff2?)\$ {
        root $INSTALL_DIR/frontend;
        expires 30d;
        add_header Cache-Control "public, no-transform";
    }
}
EOF

sudo ln -sf "$NGINX_SITE" "$NGINX_LINK"
sudo rm -f /etc/nginx/sites-enabled/default
echo "    站点配置已写入 $NGINX_SITE"

# ---------- 4. 检查并启动 Nginx ----------
log "步骤 4/7  检查配置并启动 Nginx"

if ! sudo nginx -t; then
    die "Nginx 配置有语法错误，请按上面提示修正后重新执行本脚本"
fi

sudo systemctl enable nginx >/dev/null 2>&1 || true
sudo systemctl restart nginx
sleep 1
systemctl is-active nginx >/dev/null && echo "    Nginx 已启动" || die "Nginx 启动失败：systemctl status nginx"

# ---------- 5. 后端服务 ----------
log "步骤 5/7  启动两个 Node 后端"

if [ "$USE_SYSTEMD" = "1" ]; then
    for N in 1 2; do
        sudo tee /etc/systemd/system/api-server$N.service > /dev/null << EOF
[Unit]
Description=Backend API Server $N
After=network.target

[Service]
Type=simple
User=$RUN_USER
WorkingDirectory=$INSTALL_DIR/backend
ExecStart=$NODE_BIN api-server$N.js
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
        echo "    已创建 api-server$N.service"
    done

    sudo systemctl daemon-reload
    sudo systemctl enable api-server1 api-server2 >/dev/null 2>&1 || true
    sudo systemctl restart api-server1 api-server2
    sleep 2
else
    # 没有 systemd 时用 nohup
    warn "systemd 不可用，使用 nohup 启动"
    cd "$INSTALL_DIR/backend"
    nohup "$NODE_BIN" api-server1.js > "$INSTALL_DIR/logs/server1.log" 2>&1 &
    echo $! > "$INSTALL_DIR/backend/server1.pid"
    nohup "$NODE_BIN" api-server2.js > "$INSTALL_DIR/logs/server2.log" 2>&1 &
    echo $! > "$INSTALL_DIR/backend/server2.pid"
    sleep 2
fi

# ---------- 6. 验证 ----------
log "步骤 6/7  验证部署结果"

echo "--- 端口监听状态 ---"
ss -tlnp | grep -E ':80|:4001|:4002' || warn "部分端口未监听，请查看下方 status 输出"

echo ""
echo "--- 后端服务状态 ---"
if [ "$USE_SYSTEMD" = "1" ]; then
    systemctl --no-pager --lines=0 status api-server1 api-server2 2>&1 | grep -E '●|Active' || true
else
    echo "server1 PID: $(cat "$INSTALL_DIR/backend/server1.pid" 2>/dev/null)"
    echo "server2 PID: $(cat "$INSTALL_DIR/backend/server2.pid" 2>/dev/null)"
fi

echo ""
echo "--- 直连后端测试 ---"
curl -s --max-time 5 http://127.0.0.1:4001/api/user && echo "" || echo "    服务器A 无响应"
curl -s --max-time 5 http://127.0.0.1:4002/api/user && echo "" || echo "    服务器B 无响应"

echo ""
echo "--- 通过 Nginx 测试（连续6次，观察A/B交替）---"
for i in $(seq 1 6); do
    printf "  第 %d 次 -> " "$i"
    curl -s --max-time 5 http://localhost/api/user | grep -o '"server":"[^"]*"' || echo "请求失败"
done

# ---------- 7. 完成 ----------
log "步骤 7/7  部署完成"

WINDOWS_IP=$(ip route show default | awk '{print $3}')
WSL_IP=$(hostname -I | awk '{print $1}')

cat << EOF

============================================================
 部署成功
============================================================

 本机访问：      http://localhost
 Windows 访问：  http://localhost  (新版 WSL 支持)
                 http://$WSL_IP
                 （若不通，检查 Windows 防火墙是否放行）

 WSL IP 变化：   WSL 重启后 IP 会变，可用下面的命令重看
                 hostname -I

------------------------------------------------------------
 常用运维命令
------------------------------------------------------------
 查看后端状态：  systemctl status api-server1 api-server2
 实时看日志：    journalctl -u api-server1 -f
 重启后端：      sudo systemctl restart api-server1 api-server2
 停止后端：      sudo systemctl stop api-server1 api-server2

 查看 Nginx：     systemctl status nginx
 改完配置：      sudo nginx -t && sudo systemctl reload nginx
 Nginx 错误日志：sudo tail -f /var/log/nginx/error.log
 访问日志：       sudo tail -f /var/log/nginx/access.log

 端口占用：       ss -tulnp | grep -E ':80|:4001|:4002'
 改配置：        sudo nano /etc/nginx/sites-available/nginx-app
 上游配置：      sudo nano /etc/nginx/nginx.conf  (找 upstream 块)

============================================================

 提示：WSL 并非真正开机自启，Windows 不启动 WSL 则服务不运行。
 需要开机自启请在 Windows 侧配置任务计划程序。

============================================================

EOF
