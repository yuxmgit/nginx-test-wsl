#!/bin/bash
#
# 多机远程部署脚本（由 Jenkins 调用，替代单机版 ci-deploy.sh）
#
# 工作模式：Push（Jenkins 主动 SSH 推送到目标机）
#   之所以选 Push 而非 Pull：
#   - Jenkins 跑在 WSL（NAT 内网 172.18.x.x），目标机无法反向回调 Jenkins
#   - Pull 需要目标机有公网入口 + git 凭据，还要处理目标机到 GitHub 的网络
#   - Push 只需 WSL 能出站 SSH（22 端口），网络模型最简单
#
# 用法：
#   bash deploy/remote-deploy.sh <源码目录> <inventory文件> [主机ID...]
#
# 示例：
#   bash deploy/remote-deploy.sh "$WORKSPACE" deploy/inventory.ini
#   bash deploy/remote-deploy.sh "$WORKSPACE" deploy/inventory.ini web-01
#
# 环境变量：
#   SSH_KEY_FILE   私钥路径（默认 /var/lib/jenkins/.ssh/deploy_key）
#   HEALTH_RETRIES 健康检查重试次数（默认 10）
#   DRY_RUN        =1 时只打印计划，不实际执行
#   SKIP_ROLLBACK  =1 时失败不回滚
#
set -euo pipefail

# ============ 参数区 ============
SRC_DIR="${1:-}"
INVENTORY="${2:-deploy/inventory.ini}"
shift 2 2>/dev/null || true
TARGET_HOSTS=("$@")
# ============================

SSH_KEY_FILE="${SSH_KEY_FILE:-/var/lib/jenkins/.ssh/deploy_key}"
HEALTH_RETRIES="${HEALTH_RETRIES:-10}"
DRY_RUN="${DRY_RUN:-0}"
SKIP_ROLLBACK="${SKIP_ROLLBACK:-0}"
SSH_OPTS="-i $SSH_KEY_FILE -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes"

log()  { echo -e "\033[1;36m[deploy]\033[0m $*"; }
ok()   { echo -e "\033[1;32m[ok]\033[0m $*"; }
warn() { echo -e "\033[1;33m[warn]\033[0m $*"; }
die()  { echo -e "\033[1;31m[fail]\033[0m $*" >&2; exit 1; }

[ -n "$SRC_DIR" ] || die "用法: remote-deploy.sh <源码目录> <inventory> [主机ID...]"
[ -f "$INVENTORY" ] || die "找不到 inventory 文件：$INVENTORY"
[ -d "$SRC_DIR" ] || die "源码目录不存在：$SRC_DIR"
[ -f "$SSH_KEY_FILE" ] || die "私钥不存在：$SSH_KEY_FILE；请检查 Jenkins 凭据配置"

SRC_DIR="$(cd "$SRC_DIR" && pwd)"
INVENTORY="$(cd "$(dirname "$INVENTORY")" && pwd)/$(basename "$INVENTORY")"

chmod 600 "$SSH_KEY_FILE" 2>/dev/null || true

echo "=================================================="
echo " 多机远程部署开始   $(date '+%Y-%m-%d %H:%M:%S')"
echo "=================================================="
echo " 源码目录 : $SRC_DIR"
echo " 清单文件 : $INVENTORY"
echo " 私钥     : $SSH_KEY_FILE"
if [ "$DRY_RUN" = "1" ]; then
echo " ★ DRY_RUN=1，只演练不执行"
fi
echo "=================================================="

# ---------- 解析 inventory ----------
# 产出：每台主机一个 "ID|host|ssh_user|deploy_dir|run_user|role|upstream|health_port|enabled"
parse_inventory() {
    local cur_id="" key val
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%%#*}"
        line="$(echo "$line" | sed 's/[[:space:]]*$//')"
        [ -z "$line" ] && continue
        case "$line" in
            \[*\]*)
                if [ -n "$cur_id" ]; then flush_host "$cur_id"; fi
                cur_id="${line#[}"; cur_id="${cur_id%]}"
                ;;
            *=*)
                key="$(echo "$line" | cut -d= -f1 | xargs)"
                val="$(echo "$line" | cut -d= -f2- | xargs)"
                set_key "$cur_id" "$key" "$val"
                ;;
        esac
    done < "$INVENTORY"
    [ -n "$cur_id" ] && flush_host "$cur_id"
}

# ---------- 解析目标主机地址 ----------
# 支持两种写法：
#   192.168.1.101        —— 直接 IP
#   wsl:Ubuntu-24.04     —— WSL 发行版名，运行时动态解析
# WSL 是 NAT 网络，发行版 IP 每次重启都会变，因此绝不能写死。
resolve_host() {
    local raw="$1"
    case "$raw" in
        wsl:*)
            local distro="${raw#wsl:}"
            local wsl_exe="/mnt/c/Windows/System32/wsl.exe"
            if [ ! -x "$wsl_exe" ]; then
                die "无法解析 $raw：找不到 $wsl_exe（请确认在 WSL 内运行）"
            fi
            local ip
            ip="$("$wsl_exe" -d "$distro" -- hostname -I 2>/dev/null | awk '{print $1}')"
            if [ -z "$ip" ]; then
                die "无法解析 $raw：发行版 '$distro' 未运行或未返回 IP"
            fi
            echo "$ip"
            ;;
        *)
            echo "$raw"
            ;;
    esac
}

HOST_IDS=()
declare -A H_HOST H_SSHUSER H_DIR H_RUNUSER H_ROLE H_UPSTREAM H_PORT H_ENABLED

set_key() {
    local id="$1" key="$2" val="$3"
    case "$key" in
        host)        H_HOST["$id"]="$val" ;;
        ssh_user)    H_SSHUSER["$id"]="$val" ;;
        deploy_dir)  H_DIR["$id"]="$val" ;;
        run_user)    H_RUNUSER["$id"]="$val" ;;
        role)        H_ROLE["$id"]="$val" ;;
        upstream)    H_UPSTREAM["$id"]="$val" ;;
        health_port) H_PORT["$id"]="$val" ;;
        enabled)     H_ENABLED["$id"]="$val" ;;
    esac
}

flush_host() {
    local id="$1"
    [ -n "${H_HOST[$id]:-}" ] || return 0
    HOST_IDS+=("$id")
}

parse_inventory

[ "${#HOST_IDS[@]}" -gt 0 ] || die "inventory 里没有解析到任何主机"

# 应用命令行筛选
if [ "${#TARGET_HOSTS[@]}" -gt 0 ]; then
    FILTERED=()
    for want in "${TARGET_HOSTS[@]}"; do
        found=0
        for id in "${HOST_IDS[@]}"; do
            [ "$id" = "$want" ] && found=1
        done
        [ "$found" = "1" ] || die "inventory 中没有主机：$want"
        FILTERED+=("$want")
    done
    HOST_IDS=("${FILTERED[@]}")
fi

# ---------- 公共前置校验 ----------
[ -d "$SRC_DIR/backend" ]  || die "源码缺少 backend/"
[ -d "$SRC_DIR/frontend" ] || die "源码缺少 frontend/"

# version.json 兜底：rsync --delete 会删掉目标端文件导致前端 404
if [ ! -f "$SRC_DIR/frontend/version.json" ] && [ -f "$SRC_DIR/frontend/version.json.template" ]; then
    cp "$SRC_DIR/frontend/version.json.template" "$SRC_DIR/frontend/version.json"
    warn "源目录缺少 version.json，已用模板生成占位文件"
fi

# ---------- SSH 连通性预检 ----------
log "预检 SSH 连通性"
for id in "${HOST_IDS[@]}"; do
    [ "${H_ENABLED[$id]:-true}" != "false" ] || { log "跳过 $id（enabled=false）"; continue; }
    real_host="$(resolve_host "${H_HOST[$id]}")"
    target="${H_SSHUSER[$id]}@$real_host"
    if ssh $SSH_OPTS "$target" "echo ok" >/dev/null 2>&1; then
        ok "$id  ($target) 可达"
    else
        die "$id ($target) SSH 不通；检查密钥、网络、防火墙（22 端口）"
    fi
done

# ================================================================
# 部署单台主机
# ================================================================
deploy_host() {
    local id="$1"
    local real_host
    real_host="$(resolve_host "${H_HOST[$id]}")"
    local target="${H_SSHUSER[$id]}@$real_host"
    local dest="${H_DIR[$id]}"
    local role="${H_ROLE[$id]:-full}"
    local port="${H_PORT[$id]:-80}"
    local stamp; stamp="$(date +%Y%m%d-%H%M%S)"
    local backup="/var/lib/deploy-backups/$id/$stamp"

    echo ""
    echo "=================================================="
    echo " 部署目标: $id  ($target)"
    echo " 角色    : $role    目录: $dest"
    echo "=================================================="

    if [ "$DRY_RUN" = "1" ]; then
        echo "  [DRY_RUN] 解析主机 ${H_HOST[$id]} -> $real_host"
        echo "  [DRY_RUN] rsync -> $target:$dest/{backend,frontend}"
        echo "  [DRY_RUN] systemctl restart api-server1 api-server2; reload nginx"
        echo "  [DRY_RUN] 健康检查 http://$target:$port/api/user"
        return 0
    fi

    # ---------- 步骤 1：备份（远端执行）----------
    log "[$id] 步骤 1/5  远端备份到 $backup"
    if ssh $SSH_OPTS "$target" "set -e; mkdir -p '$backup'; \
        if [ -d '$dest/backend' ]; then cp -a --no-preserve=ownership '$dest/backend' '$backup/'; fi; \
        if [ -d '$dest/frontend' ]; then cp -a --no-preserve=ownership '$dest/frontend' '$backup/'; fi; \
        mkdir -p '$dest/logs'" ; then
        ok "[$id] 备份完成"
    else
        die "[$id] 远端备份失败"
    fi

    # ---------- 步骤 2：同步 ----------
    log "[$id] 步骤 2/5  rsync 同步代码"
    local sync_ok=1
    if [ "$role" != "web" ]; then
        rsync -rl --delete -e "ssh $SSH_OPTS" \
            --exclude 'logs/' --exclude '*.log' --exclude '.git/' \
            "$SRC_DIR/backend/" "$target:$dest/backend/" || sync_ok=0
    fi
    if [ "$role" != "app" ]; then
        rsync -rl --delete -e "ssh $SSH_OPTS" \
            --exclude '.git/' \
            "$SRC_DIR/frontend/" "$target:$dest/frontend/" || sync_ok=0
    fi
    [ "$sync_ok" = "1" ] || die "[$id] rsync 同步失败"
    ok "[$id] 代码同步完成"

    # ---------- 步骤 3：校验 unit ----------
    if [ "$role" != "web" ]; then
        log "[$id] 步骤 3/5  校验 systemd unit"
        if ssh $SSH_OPTS "$target" "grep -q '^WorkingDirectory=$dest/backend' /etc/systemd/system/api-server1.service"; then
            ok "[$id] unit 与部署目录一致"
        else
            die "[$id] unit 的 WorkingDirectory 与 $dest/backend 不一致，请核对 target-prepare.sh 参数"
        fi
    else
        log "[$id] 步骤 3/5  跳过 unit 校验（role=web）"
    fi

    # ---------- 步骤 4：重启 ----------
    log "[$id] 步骤 4/5  重启服务"
    local restart_cmd=""
    [ "$role" != "web" ] && restart_cmd="sudo -n /usr/bin/systemctl restart api-server1 api-server2"
    if [ "$role" != "app" ]; then
        if ! ssh $SSH_OPTS "$target" "sudo -n /usr/sbin/nginx -t"; then
            die "[$id] 远端 nginx 配置语法错误，未重载"
        fi
        restart_cmd="$restart_cmd; sudo -n /usr/bin/systemctl reload nginx"
    fi
    if ! ssh $SSH_OPTS "$target" "$restart_cmd"; then
        die "[$id] 服务重启失败（sudo 白名单或权限问题）"
    fi
    sleep 2
    ok "[$id] 服务已重启"

    # ---------- 步骤 5：健康检查 ----------
    log "[$id] 步骤 5/5  健康检查"
    local pass=0
    for i in $(seq 1 "$HEALTH_RETRIES"); do
        local c_n c1 c2
        c_n="$(ssh $SSH_OPTS "$target" "curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:$port/api/user || echo 000" 2>/dev/null || echo 000)"
        c1="-" ; c2="-"
        if [ "$role" != "web" ]; then
            c1="$(ssh $SSH_OPTS "$target" "curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:4001/api/user || echo 000" 2>/dev/null || echo 000)"
            c2="$(ssh $SSH_OPTS "$target" "curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:4002/api/user || echo 000" 2>/dev/null || echo 000)"
        fi
        echo "    第 $i 次 -> nginx:$c_n  4001:$c1  4002:$c2"
        if [ "$c_n" = "200" ] && { [ "$role" = "web" ] || { [ "$c1" = "200" ] && [ "$c2" = "200" ]; }; }; then
            pass=1
            break
        fi
        sleep 2
    done

    if [ "$pass" != "1" ]; then
        warn "[$id] 健康检查未通过"
        if [ "$SKIP_ROLLBACK" != "1" ]; then
            log "[$id] 从 $backup 回滚"
            local rb="rsync -rl --delete '$backup/backend/' '$dest/backend/'; rsync -rl --delete '$backup/frontend/' '$dest/frontend/'"
            [ "$role" = "web" ] && rb="rsync -rl --delete '$backup/frontend/' '$dest/frontend/'"
            [ "$role" = "app" ] && rb="rsync -rl --delete '$backup/backend/' '$dest/backend/'"
            ssh $SSH_OPTS "$target" "$rb" || true
            ssh $SSH_OPTS "$target" "sudo -n /usr/bin/systemctl restart api-server1 api-server2 2>/dev/null || true; sudo -n /usr/bin/systemctl reload nginx 2>/dev/null || true" || true
            warn "[$id] 已回滚到 $backup"
        fi
        echo "--- 远端 nginx 错误日志 ---"
        ssh $SSH_OPTS "$target" "sudo -n /usr/bin/tail -n 30 /var/log/nginx/error.log 2>/dev/null || true" || true
        die "[$id] 部署失败（健康检查未通过）"
    fi
    ok "[$id] 部署成功"
}

# ================================================================
# 逐台执行，收集结果（全部执行完再汇总，不中途退出）
# ================================================================
FAILED=()
SUCCEEDED=()
for id in "${HOST_IDS[@]}"; do
    if [ "${H_ENABLED[$id]:-true}" = "false" ]; then
        log "跳过 $id（enabled=false）"
        continue
    fi
    # 用子 shell 执行：deploy_host 内部的 die 只终止子 shell，
    # 保证一台失败不影响其余主机继续部署（部分失败隔离）
    if ( deploy_host "$id" ); then
        SUCCEEDED+=("$id")
    else
        FAILED+=("$id")
        echo -e "\033[1;31m[fail]\033[0m 主机 $id 部署失败，继续部署其余主机"
    fi
done

echo ""
echo "=================================================="
echo " 多机部署汇总   $(date '+%Y-%m-%d %H:%M:%S')"
echo "=================================================="
for id in "${SUCCEEDED[@]:-}"; do [ -n "$id" ] && echo "  ✅ $id"; done
for id in "${FAILED[@]:-}";   do [ -n "$id" ] && echo "  ❌ $id"; done
echo "  成功 ${#SUCCEEDED[@]} 台 / 失败 ${#FAILED[@]} 台"
echo "=================================================="

if [ "${#FAILED[@]}" -gt 0 ]; then
    die "以下主机部署失败：${FAILED[*]}"
fi
ok "全部主机部署成功"
