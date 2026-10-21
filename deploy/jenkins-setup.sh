#!/bin/bash
#
# Jenkins 一键安装脚本（WSL Ubuntu）
#
# 用途：安装 Jenkins、配置免密 sudo、准备 jenkins 用户的 SSH 密钥
# 用法：sudo bash deploy/jenkins-setup.sh
#
# 幂等：重复执行安全
#
set -euo pipefail

RUN_USER="${RUN_USER:-$(whoami)}"
JENKINS_HOME_DIR="/var/lib/jenkins"
SSH_KEY_SOURCE="${SSH_KEY_SOURCE:-$HOME/.ssh/id_ed25519}"

log()  { echo -e "\n\033[1;36m==> $*\033[0m"; }
ok()   { echo -e "\033[1;32m[ok]\033[0m $*"; }
warn() { echo -e "\033[1;33m[warn]\033[0m $*"; }
die()  { echo -e "\033[1;31m[fail]\033[0m $*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || die "请用 sudo 运行：sudo bash deploy/jenkins-setup.sh"

# ---------- 1. systemd 检查 ----------
log "步骤 1/7  检查 systemd"
if [ "$(ps -p 1 -o comm= 2>/dev/null)" = "systemd" ]; then
    ok "systemd 已启用"
else
    die "systemd 未启用！Jenkins 无法作为服务运行。
请在 Windows 的 %UserProfile%\\.wslconfig 加入 [wsl2] systemd=true，
然后在 PowerShell 执行 wsl --shutdown，重进 Ubuntu 再跑本脚本。"
fi

# ---------- 2. Java ----------
log "步骤 2/7  安装 Java 17"
if ! command -v java >/dev/null; then
    apt update
    apt install -y fontconfig openjdk-17-jre curl rsync
else
    ok "Java 已安装：$(java -version 2>&1 | head -1)"
    apt install -y rsync 2>/dev/null || true
fi
java -version 2>&1 | head -1

# ---------- 3. Jenkins 仓库 ----------
log "步骤 3/7  配置 Jenkins 软件源"
if ! dpkg -l 2>/dev/null | grep -q "^ii  jenkins "; then
    install -d -m 0755 /usr/share/keyrings
    curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key \
        | tee /usr/share/keyrings/jenkins.io-2023.key > /dev/null
    echo "deb [signed-by=/usr/share/keyrings/jenkins.io-2023.key] https://pkg.jenkins.io/debian-stable binary/" \
        > /etc/apt/sources.list.d/jenkins.list
    apt update
    apt install -y jenkins
    ok "Jenkins 已安装"
else
    ok "Jenkins 已安装，跳过"
fi

# ---------- 4. 启动服务 ----------
log "步骤 4/7  启动 Jenkins"
systemctl enable jenkins
systemctl restart jenkins
sleep 3
if systemctl is-active --quiet jenkins; then
    ok "Jenkins 运行中"
else
    warn "Jenkins 未运行，查看日志：journalctl -u jenkins -n 50"
fi

# ---------- 5. 免密 sudo ----------
log "步骤 5/7  配置 jenkins 用户免密 sudo"
SUDOERS_FILE="/etc/sudoers.d/jenkins"
cat > "$SUDOERS_FILE" << 'EOF'
# Jenkins 自动部署专用（由 deploy/jenkins-setup.sh 生成）
jenkins ALL=(ALL) NOPASSWD: /bin/systemctl restart api-server1 api-server2
jenkins ALL=(ALL) NOPASSWD: /bin/systemctl reload nginx
jenkins ALL=(ALL) NOPASSWD: /bin/systemctl restart nginx
jenkins ALL=(ALL) NOPASSWD: /bin/systemctl status api-server1 api-server2
jenkins ALL=(ALL) NOPASSWD: /bin/systemctl status nginx
jenkins ALL=(ALL) NOPASSWD: /bin/systemctl daemon-reload
jenkins ALL=(ALL) NOPASSWD: /usr/sbin/nginx -t
jenkins ALL=(ALL) NOPASSWD: /usr/bin/rsync *
jenkins ALL=(ALL) NOPASSWD: /bin/mkdir *
jenkins ALL=(ALL) NOPASSWD: /bin/cp -a *
jenkins ALL=(ALL) NOPASSWD: /bin/rm -rf *
jenkins ALL=(ALL) NOPASSWD: /usr/bin/journalctl *
jenkins ALL=(ALL) NOPASSWD: /usr/bin/tail *
EOF
chmod 440 "$SUDOERS_FILE"
if visudo -c -f "$SUDOERS_FILE"; then
    ok "sudoers 语法校验通过"
else
    die "sudoers 语法错误，请检查 $SUDOERS_FILE"
fi

# ---------- 6. SSH 密钥 ----------
log "步骤 6/7  准备 jenkins 用户的 SSH 密钥"
if [ ! -f "$SSH_KEY_SOURCE" ]; then
    warn "未找到 SSH 私钥：$SSH_KEY_SOURCE"
    echo "  请执行以下命令生成，并把公钥添加到 GitHub："
    echo "    ssh-keygen -t ed25519 -C \"$RUN_USER@$(hostname)\""
    echo "    cat $SSH_KEY_SOURCE.pub"
    echo "  → GitHub → Settings → SSH and GPG keys → New SSH key"
else
    install -d -m 700 -o jenkins -g jenkins "$JENKINS_HOME_DIR/.ssh"
    install -m 600 -o jenkins -g jenkins "$SSH_KEY_SOURCE" "$JENKINS_HOME_DIR/.ssh/id_ed25519"
    if [ -f "${SSH_KEY_SOURCE}.pub" ]; then
        install -m 644 -o jenkins -g jenkins "${SSH_KEY_SOURCE}.pub" "$JENKINS_HOME_DIR/.ssh/id_ed25519.pub"
    fi
    # 写入 known_hosts，避免首次连接交互
    ssh-keyscan -H github.com >> "$JENKINS_HOME_DIR/.ssh/known_hosts" 2>/dev/null || true
    chown jenkins:jenkins "$JENKINS_HOME_DIR/.ssh/known_hosts" 2>/dev/null || true
    ok "SSH 密钥已安装到 $JENKINS_HOME_DIR/.ssh/"
    echo "  公钥（可添加到 GitHub）："
    cat "${SSH_KEY_SOURCE}.pub" 2>/dev/null | sed 's/^/    /'
fi

# ---------- 7. PATH 提示 ----------
log "步骤 7/7  检查 Node 路径"
if command -v node >/dev/null; then
    NODE_ABS="$(readlink -f "$(command -v node)")"
    ok "Node: $NODE_ABS"
    if [ -w /usr/local/bin ]; then
        ln -sf "$NODE_ABS" /usr/local/bin/node
        ok "已创建软链 /usr/local/bin/node -> $NODE_ABS"
    else
        warn "/usr/local/bin 不可写，请在 Jenkins 全局配置中手动添加 Node 路径"
    fi
else
    warn "未找到 node，请确保 Node 已安装（nvm 装的记得加到 Jenkins 的 PATH）"
fi

# ---------- 完成 ----------
cat << EOF

============================================================
 Jenkins 环境准备完成
============================================================

 访问地址：   http://localhost:8080
 初始密码：   sudo cat /var/lib/jenkins/secrets/initialAdminPassword

 接下来：
   1. 浏览器打开上面的地址，粘贴初始密码
   2. 选择 "Install suggested plugins"（会装 Git / Pipeline / Credentials）
   3. 创建管理员账号
   4. Manage Jenkins → System → PATH，添加：
      /usr/local/bin:/usr/bin:/bin
   5. Manage Jenkins → Credentials → 添加 SSH Username with private key
      ID 填 github-ssh，私钥粘贴 $JENKINS_HOME_DIR/.ssh/id_ed25519 的内容
   6. 新建 Pipeline 任务，Script Path 填 Jenkinsfile

 常用命令：
   sudo systemctl restart jenkins
   sudo journalctl -u jenkins -f
   sudo cat /var/lib/jenkins/secrets/initialAdminPassword

============================================================

EOF
