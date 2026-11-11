#!/bin/bash
#
# WSL 第二节点一键准备脚本（在「Jenkins 所在的 WSL 发行版」里运行）
#
# 用途：把另一台 WSL 发行版（如 Ubuntu-24.04）改造成可被 Jenkins 远程部署的
#      「模拟另一台 Ubuntu 服务器」，并自动打通 SSH 免密链路。
#
# 为什么需要这个脚本：
#   WSL 多发行版有三个真实痛点，手工处理很啰嗦：
#   1) 新发行版默认没开 systemd → 无法托管 api-server
#   2) 新发行版默认没装 sshd → Jenkins 连不上
#   3) WSL 是 NAT 网络，发行版 IP 每次重启都变 → inventory 里写死 IP 会失效
#      （本脚本让 inventory 支持 wsl:<发行版名> 语法，部署时动态解析）
#
# 用法（在 Jenkins 所在的 WSL 发行版内执行）：
#   bash deploy/wsl-second-node.sh --distro Ubuntu-24.04
#
# 可选参数：
#   --distro NAME       目标发行版名，默认 Ubuntu-24.04
#   --deploy-dir PATH   目标机部署目录，默认 /srv/nginx-project
#   --ssh-user USER     目标机登录用户，默认 deploy
#   --run-user USER     目标机服务运行用户，默认 appuser
#   --role ROLE         full | web | app，默认 full
#   --upstream LIST     upstream 后端地址，默认 127.0.0.1:4001,127.0.0.1:4002
#   --skip-prepare      只做 systemd+sshd+密钥，不执行 target-prepare.sh
#
set -euo pipefail

DISTRO="Ubuntu-24.04"
DEPLOY_DIR="/srv/nginx-project"
SSH_USER="deploy"
RUN_USER="appuser"
ROLE="full"
UPSTREAM="127.0.0.1:4001,127.0.0.1:4002"
SKIP_PREPARE=0

WSL_EXE="/mnt/c/Windows/System32/wsl.exe"
JENKINS_SSH_DIR="/var/lib/jenkins/.ssh"
DEPLOY_KEY="$JENKINS_SSH_DIR/deploy_key"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()  { echo -e "\n\033[1;36m==> $*\033[0m"; }
ok()   { echo -e "\033[1;32m[ok]\033[0m $*"; }
warn() { echo -e "\033[1;33m[warn]\033[0m $*"; }
die()  { echo -e "\033[1;31m[fail]\033[0m $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --distro)      DISTRO="$2"; shift 2 ;;
        --deploy-dir)  DEPLOY_DIR="$2"; shift 2 ;;
        --ssh-user)    SSH_USER="$2"; shift 2 ;;
        --run-user)    RUN_USER="$2"; shift 2 ;;
        --role)        ROLE="$2"; shift 2 ;;
        --upstream)    UPSTREAM="$2"; shift 2 ;;
        --skip-prepare) SKIP_PREPARE=1; shift ;;
        -h|--help)     sed -n '2,30p' "$0"; exit 0 ;;
        *)             die "未知参数：$1" ;;
    esac
done

echo "=================================================="
echo " WSL 第二节点准备"
echo "=================================================="
echo " 目标发行版 : $DISTRO"
echo " 部署目录   : $DEPLOY_DIR"
echo " 角色       : $ROLE"
echo "=================================================="

# ---------- 0. 前置检查 ----------
log "步骤 0/4  检查 WSL interop"
[ -x "$WSL_EXE" ] || die "找不到 wsl.exe（$WSL_EXE）；请确认本脚本在 WSL 内运行"
if ! "$WSL_EXE" --status >/dev/null 2>&1; then
    warn "wsl.exe --status 返回非零（沙箱内常见），继续尝试"
fi

if ! "$WSL_EXE" -d "$DISTRO" -- echo ok >/dev/null 2>&1; then
    die "无法进入发行版 '$DISTRO'。
请先在 Windows PowerShell 里安装：
    wsl --install -d $DISTRO
安装完成后重跑本脚本。"
fi
ok "发行版 $DISTRO 可访问"

# ---------- 0.5 网络模式检测 ----------
# 关键：两个 WSL 发行版必须处于同一网络模式才能直连。
#   NAT 模式      → 发行版地址在 172.18.x.x/20，彼此可直连
#   mirrored 模式 → 发行版直接用宿主机局域网 IP，也彼此可直连
#   混合模式      → NAT 的发行版无法主动访问 mirrored 的发行版（跨网段隔离）
log "步骤 0.5/4  检测两个发行版的网络模式"
SELF_IP="$(ip -4 addr show eth0 2>/dev/null | grep -oP 'inet \K[\d.]+' | head -1)"
[ -n "$SELF_IP" ] || SELF_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
TARGET_IPS_RAW="$("$WSL_EXE" -d "$DISTRO" -- hostname -I 2>/dev/null | tr -d '\r' | xargs)"
TARGET_IP="$(echo "$TARGET_IPS_RAW" | awk '{print $1}')"

inf "本发行版 IP  : ${SELF_IP:-未知}"
inf "目标发行版 IP: ${TARGET_IP:-未知}"

# 判断是否同一网段（取前两段做粗略比较）
net_prefix() { echo "$1" | cut -d. -f1,2; }
SAME_SEGMENT=0
if [ -n "$SELF_IP" ] && [ -n "$TARGET_IP" ]; then
    if [ "$(net_prefix "$SELF_IP")" = "$(net_prefix "$TARGET_IP")" ]; then
        SAME_SEGMENT=1
    fi
fi

if [ "$SAME_SEGMENT" = "1" ]; then
    ok "两发行版在同一网段（$(net_prefix "$SELF_IP").x.x）→ 可直连"
else
    warn "两发行版不在同一网段！"
    echo "    本机 $(net_prefix "$SELF_IP").x.x  vs  目标 $(net_prefix "$TARGET_IP").x.x"
    echo "    → 跨网段时 NAT 发行版无法主动访问另一侧"
    echo "    → 请把 C:\\Users\\<你>\\.wslconfig 加上 networkingMode=nat"
    echo "       然后在 Windows 执行 wsl --shutdown 重新启动两个发行版"
fi

# ---------- 1. 目标机 systemd ----------
log "步骤 1/4  在 $DISTRO 中启用 systemd"
"$WSL_EXE" -d "$DISTRO" -u root -- bash -c '
    set -e
    if [ -f /etc/wsl.conf ] && grep -q "^systemd=true" /etc/wsl.conf; then
        echo "systemd 已启用"
    else
        # 保留已有的 [user] 等段落，只确保 [boot] systemd=true
        if [ -f /etc/wsl.conf ]; then
            cp /etc/wsl.conf /etc/wsl.conf.bak
            sed -i "/^\[boot\]/,/^\[/ { /systemd=/d }" /etc/wsl.conf
            if ! grep -q "^\[boot\]" /etc/wsl.conf; then
                printf "[boot]\nsystemd=true\n\n" | cat - /etc/wsl.conf > /tmp/wsl.conf.new
                mv /tmp/wsl.conf.new /etc/wsl.conf
            else
                sed -i "/^\[boot\]/a systemd=true" /etc/wsl.conf
            fi
        else
            printf "[boot]\nsystemd=true\n" > /etc/wsl.conf
        fi
        echo "已写入 systemd=true"
    fi
    # 保证 [user] default 不丢
    if ! grep -q "^\[user\]" /etc/wsl.conf; then
        printf "\n[user]\ndefault=root\n" >> /etc/wsl.conf
    fi
' || die "配置 systemd 失败"
ok "$DISTRO 的 /etc/wsl.conf 已开启 systemd"

log "重启发行版使 systemd 生效"
"$WSL_EXE" --terminate "$DISTRO" >/dev/null 2>&1 || true
sleep 2
# 重新拉起，等待 systemd 就绪
for i in $(seq 1 20); do
    if "$WSL_EXE" -d "$DISTRO" -u root -- bash -c 'ps -p 1 -o comm= | grep -q systemd' >/dev/null 2>&1; then
        break
    fi
    sleep 1
done
if "$WSL_EXE" -d "$DISTRO" -u root -- bash -c 'ps -p 1 -o comm= | grep -q systemd' >/dev/null 2>&1; then
    ok "$DISTRO 已以 systemd 启动"
else
    warn "未检测到 systemd 为 PID 1；请手工执行 wsl --shutdown 后重试"
fi

# ---------- 2. 安装并启用 sshd ----------
log "步骤 2/4  在 $DISTRO 中安装 sshd"
"$WSL_EXE" -d "$DISTRO" -u root -- bash -c '
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq >/dev/null 2>&1 || true
    apt-get install -y -qq openssh-server >/dev/null 2>&1
    # 允许公钥登录，禁用密码（配合密钥使用）
    sed -i "s/^#\?PasswordAuthentication.*/PasswordAuthentication no/" /etc/ssh/sshd_config
    sed -i "s/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/" /etc/ssh/sshd_config
    grep -q "^PasswordAuthentication no" /etc/ssh/sshd_config || echo "PasswordAuthentication no" >> /etc/ssh/sshd_config
    grep -q "^PubkeyAuthentication yes" /etc/ssh/sshd_config || echo "PubkeyAuthentication yes" >> /etc/ssh/sshd_config
    mkdir -p /run/sshd
    systemctl enable ssh 2>/dev/null || systemctl enable sshd 2>/dev/null || true
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
    systemctl is-active ssh >/dev/null 2>&1 && echo "sshd 运行中" || echo "sshd 状态异常"
' || die "安装 sshd 失败"
ok "sshd 已安装并启动"

# ---------- 3. SSH 密钥 ----------
log "步骤 3/4  准备部署密钥并授权"
install -d -m 700 -o jenkins -g jenkins "$JENKINS_SSH_DIR"
if [ ! -f "$DEPLOY_KEY" ]; then
    if [ "$(id -u)" = "0" ]; then
        ssh-keygen -t ed25519 -N '' -f "$DEPLOY_KEY" -C "jenkins@wsl-deploy"
    else
        sudo ssh-keygen -t ed25519 -N '' -f "$DEPLOY_KEY" -C "jenkins@wsl-deploy"
    fi
    ok "已生成部署私钥 $DEPLOY_KEY"
else
    ok "部署私钥已存在"
fi
chmod 600 "$DEPLOY_KEY"
chown jenkins:jenkins "$DEPLOY_KEY" 2>/dev/null || true
PUBKEY="$(cat "$DEPLOY_KEY.pub")"

# 把公钥写进目标机的 deploy 用户
"$WSL_EXE" -d "$DISTRO" -u root -- bash -c "
    set -e
    id $SSH_USER >/dev/null 2>&1 || useradd -m -s /bin/bash $SSH_USER
    install -d -m 700 -o $SSH_USER -g $SSH_USER /home/$SSH_USER/.ssh
    touch /home/$SSH_USER/.ssh/authorized_keys
    grep -qF '$PUBKEY' /home/$SSH_USER/.ssh/authorized_keys 2>/dev/null || echo '$PUBKEY' >> /home/$SSH_USER/.ssh/authorized_keys
    chmod 600 /home/$SSH_USER/.ssh/authorized_keys
    chown $SSH_USER:$SSH_USER /home/$SSH_USER/.ssh/authorized_keys
" || die "授权公钥失败"
ok "公钥已授权给 $DISTRO 的 $SSH_USER 用户"

# ---------- 4. 执行 target-prepare.sh ----------
if [ "$SKIP_PREPARE" = "1" ]; then
    log "步骤 4/4  跳过 target-prepare.sh（--skip-prepare）"
else
    log "步骤 4/4  在 $DISTRO 中执行 target-prepare.sh"
    # 通过 stdin 把脚本送进去，避免跨发行版的路径/挂载差异
    cat "$SCRIPT_DIR/target-prepare.sh" | "$WSL_EXE" -d "$DISTRO" -u root -- bash -s -- \
        --deploy-dir "$DEPLOY_DIR" \
        --ssh-user "$SSH_USER" \
        --run-user "$RUN_USER" \
        --role "$ROLE" \
        --upstream "$UPSTREAM" || die "target-prepare.sh 执行失败"
    ok "$DISTRO 已就绪"
fi

# ---------- 5. SSH 连通性实测 ----------
log "步骤 5/5  实测 SSH 连通性"
SSH_OK=0
if [ -n "$TARGET_IP" ]; then
    if timeout 8 ssh -i "$DEPLOY_KEY" \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=5 -o BatchMode=yes \
        "$SSH_USER@$TARGET_IP" "echo ok" >/dev/null 2>&1; then
        ok "SSH 免密登录成功：$SSH_USER@$TARGET_IP"
        SSH_OK=1
    else
        warn "SSH 连接失败（$SSH_USER@$TARGET_IP）"
        echo "    排查顺序："
        echo "      1) 目标机 sshd 是否在跑：wsl -d $DISTRO -- systemctl is-active ssh"
        echo "      2) 是否跨网段（本机 $(net_prefix "$SELF_IP").x / 目标 $(net_prefix "$TARGET_IP").x）"
        echo "      3) 私钥权限：ls -l $DEPLOY_KEY（应为 600，属主 jenkins）"
    fi
else
    warn "拿不到目标 IP，跳过 SSH 实测"
fi

# ---------- 汇总 ----------
cat << EOF

============================================================
 第二节点准备完成
============================================================

 目标发行版 : $DISTRO
 目标 IP     : $TARGET_IP
 本机 IP     : $SELF_IP
 登录用户    : $SSH_USER
 部署目录    : $DEPLOY_DIR
 角    色    : $ROLE
 SSH 免密    : $([ "$SSH_OK" = "1" ] && echo "已验证通过" || echo "未通过（见上方排查建议）")

 ------------------------------------------------------------
 下一步：配置 inventory.ini
 ------------------------------------------------------------
 在仓库里编辑 deploy/inventory.ini，写成：

    [$DISTRO]
    host        = wsl:$DISTRO
    ssh_user    = $SSH_USER
    deploy_dir  = $DEPLOY_DIR
    run_user    = $RUN_USER
    role        = $ROLE
    health_port = 80
    enabled     = true

 host 用 "wsl:$DISTRO" 而不是写死 IP！
 WSL 发行版 IP 每次重启都会变，remote-deploy.sh 会在部署时
 自动调用 wsl.exe 解析真实 IP。（若两发行版跨网段无法直连，
 需先统一 networkingMode=nat，见步骤 0.5 的提示）

 ------------------------------------------------------------
 验证 SSH 链路
 ------------------------------------------------------------
    sudo -u jenkins ssh -i $DEPLOY_KEY \\
        -o StrictHostKeyChecking=no $SSH_USER@$TARGET_IP "hostname; whoami"

 ------------------------------------------------------------
 试部署（不真的改文件）
 ------------------------------------------------------------
    sudo -u jenkins bash deploy/remote-deploy.sh \\
        /var/lib/jenkins/workspace/nginx-deploy \\
        deploy/inventory.ini $DISTRO --dry-run

============================================================

EOF
