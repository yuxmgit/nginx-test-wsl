#!/bin/bash
#
# 目标机一次性准备脚本（在「另一台 Ubuntu」上以 root 运行）
#
# 作用：把一台裸 Ubuntu 变成可被 Jenkins 远程部署的节点。
#   - 安装 node / nginx / rsync / acl
#   - 创建部署用户 deploy（登录用）与运行用户 appuser（跑服务用），两者分离
#   - 建立部署目录并授权
#   - 生成 api-server1/2 systemd unit
#   - 生成 nginx 站点配置 + upstream 块
#   - 生成受限 sudo 白名单（只允许重启本项目服务）
#
# 用法（在目标机上）：
#   sudo bash deploy/target-prepare.sh \
#       --deploy-dir /srv/nginx-project \
#       --upstream 127.0.0.1:4001,127.0.0.1:4002 \
#       --role full
#
# 幂等：可重复执行。
#
set -euo pipefail

# ============ 参数区 ============
DEPLOY_DIR="/srv/nginx-project"
UPSTREAM_SERVERS="127.0.0.1:4001,127.0.0.1:4002"
ROLE="full"                 # full | web | app
SSH_USER="deploy"           # 远程登录用户
RUN_USER="appuser"          # 服务运行用户
NODE_MAJOR="22"
NGINX_SITE="/etc/nginx/sites-available/nginx-app"
# ============================

log()  { echo -e "\n\033[1;36m==> $*\033[0m"; }
ok()   { echo -e "\033[1;32m[ok]\033[0m $*"; }
warn() { echo -e "\033[1;33m[warn]\033[0m $*"; }
die()  { echo -e "\033[1;31m[fail]\033[0m $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --deploy-dir)  DEPLOY_DIR="$2"; shift 2 ;;
        --upstream)    UPSTREAM_SERVERS="$2"; shift 2 ;;
        --role)        ROLE="$2"; shift 2 ;;
        --ssh-user)    SSH_USER="$2"; shift 2 ;;
        --run-user)    RUN_USER="$2"; shift 2 ;;
        --node-major)  NODE_MAJOR="$2"; shift 2 ;;
        -h|--help)     sed -n '2,25p' "$0"; exit 0 ;;
        *)             die "未知参数：$1" ;;
    esac
done

[ "$(id -u)" = "0" ] || die "请用 sudo 运行"
command -v systemctl >/dev/null || die "systemd 未启用，无法托管服务"

echo "=================================================="
echo " 目标机准备"
echo "=================================================="
echo " 部署目录 : $DEPLOY_DIR"
echo " 角色     : $ROLE"
echo " upstream : $UPSTREAM_SERVERS"
echo " 登录用户 : $SSH_USER   运行用户 : $RUN_USER"
echo "=================================================="

# ---------- 1. 依赖 ----------
log "步骤 1/7  安装依赖"
apt update -qq
DEBIAN_FRONTEND=noninteractive apt install -y -qq curl rsync acl nginx ca-certificates >/dev/null
ok "nginx / rsync / acl / curl 已安装"

if ! command -v node >/dev/null; then
    log "安装 Node.js $NODE_MAJOR"
    curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash - >/dev/null
    DEBIAN_FRONTEND=noninteractive apt install -y -qq nodejs >/dev/null
fi
NODE_BIN="$(command -v node)"
ok "Node: $NODE_BIN ($($NODE_BIN -v))"

# ---------- 2. 用户 ----------
log "步骤 2/7  创建用户"
if ! id "$SSH_USER" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "$SSH_USER"
    ok "已创建登录用户 $SSH_USER"
else
    ok "登录用户 $SSH_USER 已存在"
fi

if [ "$RUN_USER" != "$SSH_USER" ]; then
    if ! id "$RUN_USER" >/dev/null 2>&1; then
        useradd -m -s /bin/bash "$RUN_USER"
        ok "已创建运行用户 $RUN_USER"
    else
        ok "运行用户 $RUN_USER 已存在"
    fi
fi

# ---------- 3. 目录与权限 ----------
log "步骤 3/7  准备部署目录 $DEPLOY_DIR"
install -d -o "$RUN_USER" -g "$RUN_USER" -m 0755 "$DEPLOY_DIR"
install -d -o "$RUN_USER" -g "$RUN_USER" -m 0755 "$DEPLOY_DIR/logs"
install -d -o "$SSH_USER" -g "$SSH_USER" -m 0750 /var/lib/deploy-backups

# 登录用户（rsync 写入方）与运行用户（读代码方）都要能访问
setfacl -m "u:$SSH_USER:rwX" "$DEPLOY_DIR"
setfacl -m "u:$SSH_USER:rwX" "$DEPLOY_DIR/logs"
setfacl -R -m "u:$RUN_USER:rX" "$DEPLOY_DIR" 2>/dev/null || true
setfacl -m "u:$RUN_USER:rX" "$DEPLOY_DIR"
find "$DEPLOY_DIR" -type d -exec setfacl -m "d:u:$SSH_USER:rwX" -m "d:u:$RUN_USER:rX" {} + 2>/dev/null || true
ok "目录就绪，$SSH_USER 可写，$RUN_USER 可读"
echo "    备份根目录：/var/lib/deploy-backups（属主 $SSH_USER）"

# ---------- 4. systemd unit ----------
if [ "$ROLE" != "web" ]; then
    log "步骤 4/7  生成 systemd unit"
    for N in 1 2; do
        cat > "/etc/systemd/system/api-server$N.service" << EOF
[Unit]
Description=Backend API Server $N
After=network.target

[Service]
Type=simple
User=$RUN_USER
WorkingDirectory=$DEPLOY_DIR/backend
ExecStart=$NODE_BIN api-server$N.js
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
        ok "已写入 api-server$N.service"
    done
    systemctl daemon-reload
    systemctl enable api-server1 api-server2 >/dev/null 2>&1 || true
else
    log "步骤 4/7  跳过 systemd unit（role=web）"
fi

# ---------- 5. nginx ----------
if [ "$ROLE" != "app" ]; then
    log "步骤 5/7  生成 nginx 配置"
    UPSTREAM_LINES=""
    IFS=',' read -ra _ups <<< "$UPSTREAM_SERVERS"
    for u in "${_ups[@]}"; do
        u="$(echo "$u" | xargs)"
        [ -n "$u" ] && UPSTREAM_LINES+="        server $u;"$'\n'
    done

    # upstream 块放在 http {} 内。优先写独立 conf.d 文件（比改 nginx.conf 更干净）
    mkdir -p /etc/nginx/conf.d
    cat > /etc/nginx/conf.d/api-upstream.conf << EOF
upstream api_backend {
$(echo "$UPSTREAM_LINES" | sed 's/^        /    /')
}
EOF

    sudo_tee_site() {
        cat > "$NGINX_SITE"
    }
    sudo_tee_site << EOF
server {
    listen 80;
    listen [::]:80;
    server_name _;

    location / {
        root $DEPLOY_DIR/frontend;
        index index.html;
        try_files \$uri \$uri/ /index.html;
    }

    location /api/ {
        proxy_pass http://api_backend;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location ~* \.(css|js|png|jpg|jpeg|gif|ico|svg|woff2?)\$ {
        root $DEPLOY_DIR/frontend;
        expires 30d;
        add_header Cache-Control "public, no-transform";
    }
}
EOF
    ln -sf "$NGINX_SITE" /etc/nginx/sites-enabled/nginx-app
    rm -f /etc/nginx/sites-enabled/default

    if nginx -t; then
        systemctl enable nginx >/dev/null 2>&1 || true
        systemctl restart nginx
        ok "nginx 配置生效"
    else
        die "nginx 配置语法错误"
    fi
else
    log "步骤 5/7  跳过 nginx 配置（role=app）"
fi

# ---------- 6. 受限 sudo ----------
log "步骤 6/7  配置受限 sudo"
SUDOERS_FILE="/etc/sudoers.d/deploy-nginx-app"
cat > "$SUDOERS_FILE" << EOF
# 远程部署专用白名单（由 target-prepare.sh 生成）
$SSH_USER ALL=(root) NOPASSWD: /usr/bin/systemctl restart api-server1 api-server2
$SSH_USER ALL=(root) NOPASSWD: /usr/bin/systemctl reload nginx
$SSH_USER ALL=(root) NOPASSWD: /usr/bin/systemctl restart nginx
$SSH_USER ALL=(root) NOPASSWD: /usr/sbin/nginx -t
$SSH_USER ALL=(root) NOPASSWD: /usr/bin/journalctl -u api-server1 --no-pager --lines=40
$SSH_USER ALL=(root) NOPASSWD: /usr/bin/journalctl -u api-server2 --no-pager --lines=40
$SSH_USER ALL=(root) NOPASSWD: /usr/bin/tail -n 30 /var/log/nginx/error.log
EOF
chmod 440 "$SUDOERS_FILE"
visudo -c -f "$SUDOERS_FILE" >/dev/null || die "sudoers 语法错误"
ok "sudoers 白名单已生效：$SUDOERS_FILE"

# ---------- 7. 汇总 ----------
log "步骤 7/7  完成"
cat << EOF

============================================================
 目标机准备完成
============================================================

 部署目录 : $DEPLOY_DIR
 登录用户 : $SSH_USER
 运行用户 : $RUN_USER
 角    色 : $ROLE
 upstream : $UPSTREAM_SERVERS

 接下来在 Jenkins 侧做三件事：

 1) 生成部署密钥（若已有可跳过）：
      sudo ssh-keygen -t ed25519 -N '' -f /var/lib/jenkins/.ssh/deploy_key

 2) 把公钥授权给登录用户：
      sudo install -d -m 700 -o $SSH_USER -g $SSH_USER /home/$SSH_USER/.ssh
      sudo tee /home/$SSH_USER/.ssh/authorized_keys > /dev/null
      sudo chmod 600 /home/$SSH_USER/.ssh/authorized_keys
      sudo chown $SSH_USER:$SSH_USER /home/$SSH_USER/.ssh/authorized_keys
      # 然后把 deploy_key.pub 内容粘进去

 3) 在 Jenkins 凭据里新增：
      类型      SSH Username with private key
      ID        deploy-target-key
      Username  $SSH_USER
      私钥      /var/lib/jenkins/.ssh/deploy_key 的内容

============================================================

EOF
