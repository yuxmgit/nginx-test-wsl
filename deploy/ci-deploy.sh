#!/bin/bash
#
# CI/CD 无人值守部署脚本（供 Jenkins 调用）
#
# 与 deploy.sh 的区别：
#   deploy.sh   面向人工，交互式提问、首次安装 nginx/systemd
#   ci-deploy.sh 面向 CI，零交互、幂等、失败自动回滚
#
# 用法：
#   bash deploy/ci-deploy.sh <源码目录> [目标目录]
#
# 示例：
#   bash deploy/ci-deploy.sh /var/lib/jenkins/workspace/nginx-deploy /home/yuxiangming/nginx-project
#
# 环境变量（可选）：
#   SKIP_BACKUP=1     跳过备份（首次部署时用）
#   SKIP_RESTART=1    只同步文件，不重启服务
#   HEALTH_RETRIES=10 健康检查重试次数（默认 10，每次间隔 2 秒）
#
set -euo pipefail

# ============ 参数区 ============
SRC_DIR="${1:-}"
DEST_DIR="${2:-$HOME/nginx-project}"

if [ -z "$SRC_DIR" ]; then
    echo "[错误] 必须传入源码目录。用法: ci-deploy.sh <源码目录> [目标目录]" >&2
    exit 1
fi

SRC_DIR="$(cd "$SRC_DIR" && pwd)"
DEST_DIR="$(cd "$DEST_DIR" 2>/dev/null && pwd || echo "$DEST_DIR")"

SKIP_BACKUP="${SKIP_BACKUP:-0}"
SKIP_RESTART="${SKIP_RESTART:-0}"
HEALTH_RETRIES="${HEALTH_RETRIES:-10}"
RUN_USER="${RUN_USER:-$(whoami)}"
NODE_BIN="$(command -v node || echo /usr/bin/node)"
BACKUP_ROOT="${BACKUP_ROOT:-/var/lib/jenkins/deploy-backups}"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$BACKUP_ROOT/$STAMP"

log()  { echo -e "\033[1;36m[deploy]\033[0m $*"; }
ok()   { echo -e "\033[1;32m[ok]\033[0m $*"; }
warn() { echo -e "\033[1;33m[warn]\033[0m $*"; }
die()  { echo -e "\033[1;31m[fail]\033[0m $*" >&2; exit 1; }

echo "=================================================="
echo " CI 部署开始   $(date '+%Y-%m-%d %H:%M:%S')"
echo "=================================================="
echo " 源码目录 : $SRC_DIR"
echo " 部署目标 : $DEST_DIR"
echo " 运行用户 : $RUN_USER"
echo " Node     : $NODE_BIN ($($NODE_BIN -v 2>/dev/null || echo '未找到'))"
echo "=================================================="

# ---------- 0. 前置校验 ----------
[ -d "$SRC_DIR/backend" ]  || die "源码目录缺少 backend/：$SRC_DIR"
[ -d "$SRC_DIR/frontend" ] || die "源码目录缺少 frontend/：$SRC_DIR"
[ -f "$SRC_DIR/backend/api-server1.js" ] || die "缺少 backend/api-server1.js"
[ -f "$SRC_DIR/backend/api-server2.js" ] || die "缺少 backend/api-server2.js"

command -v node >/dev/null || die "未找到 node，请确认 Jenkins 环境的 PATH（$NODE_BIN）"
command -v rsync >/dev/null || die "未安装 rsync，请执行: sudo apt install -y rsync"

[ -d "$DEST_DIR" ] || die "部署目录不存在：$DEST_DIR；请先运行 jenkins-setup.sh"
[ -x "$DEST_DIR" ] && [ -w "$DEST_DIR" ] || die "当前用户 $(whoami) 无权访问或写入 $DEST_DIR；请重新运行 jenkins-setup.sh 配置 ACL"
[ -w "$BACKUP_ROOT" ] || die "当前用户 $(whoami) 无权写入备份目录 $BACKUP_ROOT"

# ---------- 1. 备份当前版本（用于回滚）----------
if [ "$SKIP_BACKUP" = "1" ] || [ ! -d "$DEST_DIR/backend" ]; then
    log "步骤 1/5  跳过备份（首次部署或 SKIP_BACKUP=1）"
else
    log "步骤 1/5  备份当前版本到 $BACKUP_DIR"
    mkdir -p "$BACKUP_DIR"
    cp -a --no-preserve=ownership "$DEST_DIR/backend" "$BACKUP_DIR/"
    cp -a --no-preserve=ownership "$DEST_DIR/frontend" "$BACKUP_DIR/"
    # 只保留最近 5 份
    find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' \
        | sort -nr | tail -n +6 | cut -d' ' -f2- \
        | while IFS= read -r old_backup; do
            [ -n "$old_backup" ] && rm -rf -- "$old_backup"
        done
    ok "备份完成"
fi

# ---------- 2. 同步代码 ----------
log "步骤 2/5  同步 backend/ frontend/ 到 $DEST_DIR"
mkdir -p "$DEST_DIR/logs"
rsync -rl --delete \
    --exclude 'logs/' \
    --exclude '*.log' \
    --exclude '.git/' \
    "$SRC_DIR/backend/"  "$DEST_DIR/backend/"
rsync -rl --delete \
    --exclude '.git/' \
    "$SRC_DIR/frontend/" "$DEST_DIR/frontend/"
chmod +r "$DEST_DIR"/backend/*.js
ok "代码同步完成"

# ---------- 3. 检查 systemd unit ----------
log "步骤 3/5  校验 systemd 服务配置"
for N in 1 2; do
    UNIT="/etc/systemd/system/api-server$N.service"
    if [ ! -f "$UNIT" ]; then
        die "未找到 $UNIT；请由管理员先创建并启用后端 systemd unit"
    fi

    UNIT_USER="$(grep -m1 '^User=' "$UNIT" | cut -d= -f2- || true)"
    UNIT_DIR="$(grep -m1 '^WorkingDirectory=' "$UNIT" | cut -d= -f2- || true)"
    UNIT_NODE="$(grep -m1 '^ExecStart=' "$UNIT" | cut -d= -f2- | awk '{print $1}' || true)"
    [ "$UNIT_USER" = "$RUN_USER" ] || die "$UNIT 的 User=$UNIT_USER，与 DEPLOY_USER=$RUN_USER 不一致"
    [ "$UNIT_DIR" = "$DEST_DIR/backend" ] || die "$UNIT 的 WorkingDirectory=$UNIT_DIR，与部署目录不一致"
    if [ -n "$UNIT_NODE" ] && [ ! -x "$UNIT_NODE" ]; then
        die "$UNIT 的 Node 路径无效：$UNIT_NODE；请由管理员修正 unit"
    else
        echo "    api-server$N.service  配置正常"
    fi
done

# ---------- 4. 重启服务 ----------
if [ "$SKIP_RESTART" = "1" ]; then
    log "步骤 4/5  跳过服务重启（SKIP_RESTART=1）"
else
    log "步骤 4/5  重启后端并重载 Nginx"
    sudo -n /usr/bin/systemctl restart api-server1 api-server2
    sleep 2
    for N in 1 2; do
        if systemctl is-active --quiet "api-server$N"; then
            ok "api-server$N 运行中"
        else
            warn "api-server$N 未运行；请检查 Jenkins 构建日志或 journalctl"
        fi
    done

    if sudo -n /usr/sbin/nginx -t; then
        sudo -n /usr/bin/systemctl reload nginx || sudo -n /usr/bin/systemctl restart nginx
        ok "Nginx 已重载"
    else
        die "Nginx 配置语法错误，未重载"
    fi
fi

# ---------- 5. 健康检查（失败自动回滚）----------
log "步骤 5/5  健康检查"
PASS=0
for i in $(seq 1 "$HEALTH_RETRIES"); do
    C1=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:4001/api/user || echo 000)
    C2=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:4002/api/user || echo 000)
    CN=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1/api/user || echo 000)
    echo "    第 $i 次 -> 4001:$C1  4002:$C2  nginx:$CN"
    if [ "$C1" = "200" ] && [ "$C2" = "200" ] && [ "$CN" = "200" ]; then
        PASS=1
        break
    fi
    sleep 2
done

if [ "$PASS" != "1" ]; then
    echo ""
    warn "健康检查未通过，尝试回滚到备份版本"
    if [ -d "$BACKUP_DIR/backend" ]; then
        rsync -rl --delete "$BACKUP_DIR/backend/"  "$DEST_DIR/backend/"
        rsync -rl --delete "$BACKUP_DIR/frontend/" "$DEST_DIR/frontend/"
        sudo -n /usr/bin/systemctl restart api-server1 api-server2 || true
        sudo -n /usr/bin/systemctl reload nginx || true
        echo "已回滚到 $BACKUP_DIR"
    else
        warn "没有可用备份，跳过回滚"
    fi
    echo "--- nginx 错误日志 ---"
    sudo -n /usr/bin/tail -n 30 /var/log/nginx/error.log 2>/dev/null || true
    die "部署失败（健康检查未通过）"
fi

echo ""
echo "=================================================="
echo -e "\033[1;32m 部署成功\033[0m   $(date '+%Y-%m-%d %H:%M:%S')"
echo "=================================================="
curl -s --max-time 5 http://127.0.0.1/api/user; echo ""
echo "备份位置: $BACKUP_DIR"
