#!/bin/bash
#
# WSL 多机部署 —— 一站式引导脚本（状态机式）
#
# 设计目标：把「装发行版 → 统一网络 → 装环境 → 打通 SSH → 配清单 → 试部署」
# 拆成若干阶段，用户只需反复执行同一条命令，脚本自动判断进度继续往下走。
#
# 用法（在 Jenkins 所在的 WSL 发行版内执行）：
#   bash deploy/wsl-setup-all.sh
#   bash deploy/wsl-setup-all.sh --distro Ubuntu-24.04
#   bash deploy/wsl-setup-all.sh --status      # 只看进度，不执行
#
# 阶段说明：
#   1. 统一 WSL 网络模式（写 .wslconfig 的 networkingMode=nat）
#   2. 等待 wsl --shutdown 生效后重新进入发行版
#   3. 准备目标发行版（systemd / sshd / 密钥 / 部署目录 / systemd unit / nginx）
#   4. 打通 SSH 免密 + 自动写入 inventory.ini
#   5. 试部署（dry-run）
#
set -uo pipefail

DISTRO="Ubuntu-24.04"
# 解析参数：--distro NAME / --status
ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --distro) DISTRO="$2"; shift 2 ;;
        --status) ARGS+=("--status"); shift ;;
        *) ARGS+=("$1"); shift ;;
    esac
done
POSITIONAL=("${ARGS[@]:-}")

DEPLOY_DIR="/srv/nginx-project"
SSH_USER="deploy"
RUN_USER="appuser"
ROLE="full"
UPSTREAM="127.0.0.1:4001,127.0.0.1:4002"
PORT=80

WSL_EXE="/mnt/c/Windows/System32/wsl.exe"
# Windows 用户目录：优先用 wslpath 反查 $HOME（$HOME 本身就是 /mnt/c/Users/<名字>）
WIN_HOME="$(wslpath -u "$(cmd.exe /c echo %USERPROFILE% 2>/dev/null | tr -d '\r')" 2>/dev/null || true)"
if [ -z "$WIN_HOME" ] || [ ! -d "$WIN_HOME" ]; then
    # 兜底：从 /mnt/c/Users 下找与当前用户同名的目录
    WIN_HOME="$(dirname "$HOME" 2>/dev/null)"
    if [ ! -f "$WIN_HOME/.wslconfig" ]; then
        WIN_HOME="/mnt/c/Users/$(cmd.exe /c echo %USERNAME% 2>/dev/null | tr -d '\r')"
    fi
fi
WSLCONF="$WIN_HOME/.wslconfig"
JENKINS_SSH_DIR="/var/lib/jenkins/.ssh"
DEPLOY_KEY="$JENKINS_SSH_DIR/deploy_key"
STATE_FILE="$HOME/.wsl-sim-state"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---------- 输出helper ----------
step() { echo; echo -e "\033[1;36m╔══ $* ══╗\033[0m"; }
info() { echo -e "  \033[0;37m·\033[0m $*"; }
ok()   { echo -e "  \033[1;32m✔\033[0m $*"; }
warn() { echo -e "  \033[1;33m!\033[0m $*"; }
err()  { echo -e "  \033[1;31m✘\033[0m $*"; }
die()  { err "$*"; exit 1; }

# ---------- 状态 ----------
get_state() { [ -f "$STATE_FILE" ] && cat "$STATE_FILE" || echo 0; }
set_state() { echo "$1" > "$STATE_FILE"; }

net_prefix() { echo "$1" | cut -d. -f1,2; }

self_ip() {
    ip -4 addr show eth0 2>/dev/null | grep -oP 'inet \K[\d.]+' | head -1
}
target_ip() {
    "$WSL_EXE" -d "$DISTRO" -- hostname -I 2>/dev/null | tr -d '\r' | awk '{print $1}'
}

banner() {
cat << EOF

╔══════════════════════════════════════════════════════════════╗
║   WSL 多机部署引导   ·   目标发行版: $DISTRO
╚══════════════════════════════════════════════════════════════╝

EOF
}

# ================================================================
# 阶段 1：统一网络模式
# ================================================================
stage_network() {
    step "阶段 1/5  统一 WSL 网络模式"

    local current_mode
    current_mode="$(grep -i 'networkingMode' "$WSLCONF" 2>/dev/null | head -1 | tr -d '\r' | sed 's/.*=//' | xargs)"
    info "当前 .wslconfig 里的 networkingMode: ${current_mode:-（未设置，默认 nat）}"

    if [ -n "$current_mode" ] && [ "$current_mode" != "nat" ]; then
        ok "已经是 nat 模式，无需修改"
    else
        # 确保有 networkingMode=nat
        if command -v python3 >/dev/null 2>&1; then
            [ -f "$WSLCONF" ] && cp "$WSLCONF" "$WSLCONF.bak.$(date +%Y%m%d-%H%M%S)"
            python3 - "$WSLCONF" <<'PY'
import io, re, sys
p = sys.argv[1]
try:
    s = io.open(p, encoding='utf-8-sig').read()
except FileNotFoundError:
    s = '[wsl2]\n'
# 去掉所有 networkingMode 行
s = re.sub(r'^[ \t]*networkingMode[ \t]*=.*$', '', s, flags=re.M)
# 压缩连续空行、去掉首尾空行
s = re.sub(r'\n{3,}', '\n\n', s).strip('\n')
lines = s.split('\n')
out, in_wsl2, inserted = [], False, False
for ln in lines:
    st = ln.strip()
    if st.startswith('['):
        # 离开 [wsl2] 段之前补上
        if in_wsl2 and not inserted:
            out.append('networkingMode=nat')
            inserted = True
        in_wsl2 = (st == '[wsl2]')
    out.append(ln)
if in_wsl2 and not inserted:
    out.append('networkingMode=nat')
io.open(p, 'w', encoding='utf-8-sig', newline='\n').write('\n'.join(out) + '\n')
PY
            ok "已写入 networkingMode=nat（已备份 .wslconfig.bak.*）"
        else
            warn "无法自动改写 $WSLCONF（缺 python3 或文件不存在）"
            echo "     请手工确保 [wsl2] 段里有:  networkingMode=nat"
        fi
    fi

    echo
    echo "  当前 .wslconfig："
    sed 's/^/    /' "$WSLCONF" 2>/dev/null
}

# ================================================================
# 阶段 2：检查两发行版是否同网段
# ================================================================
stage_check_network() {
    step "阶段 2/5  检查两个发行版的网络"

    local s_ip t_ip
    s_ip="$(self_ip)"
    t_ip="$(target_ip)"

    info "本发行版 IP  : ${s_ip:-（读取失败）}"
    info "目标发行版 IP: ${t_ip:-（读取失败）}"

    if [ -z "$s_ip" ] || [ -z "$t_ip" ]; then
        warn "读不到 IP。目标发行版可能未运行，请先在 Windows 执行：wsl -d $DISTRO"
        return 1
    fi

    if [ "$(net_prefix "$s_ip")" = "$(net_prefix "$t_ip")" ]; then
        ok "同网段（$(net_prefix "$s_ip").x.x）→ 可以直连"
        return 0
    fi

    err "跨网段！本机 $(net_prefix "$s_ip").x.x  vs  目标 $(net_prefix "$t_ip").x.x"
    echo
    echo "  WSL 发行版处于不同网络模式时，NAT 一侧无法主动访问另一侧。"
    echo "  必须执行 wsl --shutdown 让新配置生效："
    echo
    echo -e "    \033[1;33mwsl --shutdown\033[0m        ← 在 Windows PowerShell 里执行"
    echo
    echo "  执行后重新进入本发行版，再跑一次本脚本即可自动继续。"
    return 1
}

# ================================================================
# 阶段 3：准备目标发行版
# ================================================================
stage_prepare() {
    step "阶段 3/5  准备目标发行版 $DISTRO"

    # 3.1 systemd
    info "检查 systemd…"
    if "$WSL_EXE" -d "$DISTRO" -u root -- bash -c 'ps -p 1 -o comm= | grep -q systemd' >/dev/null 2>&1; then
        ok "systemd 已启用"
    else
        warn "systemd 未启用，写入 /etc/wsl.conf…"
        "$WSL_EXE" -d "$DISTRO" -u root -- bash -c '
            if ! grep -q "^systemd=true" /etc/wsl.conf 2>/dev/null; then
                if [ -f /etc/wsl.conf ] && grep -q "^\[boot\]" /etc/wsl.conf; then
                    sed -i "/^\[boot\]/a systemd=true" /etc/wsl.conf
                else
                    printf "[boot]\nsystemd=true\n" >> /etc/wsl.conf
                fi
            fi
            grep -q "^\[user\]" /etc/wsl.conf 2>/dev/null || printf "\n[user]\ndefault=root\n" >> /etc/wsl.conf
        ' >/dev/null 2>&1
        "$WSL_EXE" --terminate "$DISTRO" >/dev/null 2>&1 || true
        sleep 3
        if "$WSL_EXE" -d "$DISTRO" -u root -- bash -c 'ps -p 1 -o comm= | grep -q systemd' >/dev/null 2>&1; then
            ok "systemd 已启用（已重启发行版）"
        else
            err "systemd 仍未启用，请检查 $DISTRO 的 /etc/wsl.conf"
            return 1
        fi
    fi

    # 3.2 sshd
    info "安装/启动 sshd…"
    "$WSL_EXE" -d "$DISTRO" -u root -- bash -c '
        set -e
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq >/dev/null 2>&1 || true
        if ! dpkg -s openssh-server >/dev/null 2>&1; then
            apt-get install -y -qq openssh-server >/dev/null 2>&1
        fi
        sed -i "s/^#\?PasswordAuthentication.*/PasswordAuthentication no/" /etc/ssh/sshd_config
        grep -q "^PasswordAuthentication no" /etc/ssh/sshd_config || echo "PasswordAuthentication no" >> /etc/ssh/sshd_config
        grep -q "^PubkeyAuthentication yes" /etc/ssh/sshd_config || echo "PubkeyAuthentication yes" >> /etc/ssh/sshd_config
        mkdir -p /run/sshd
        systemctl enable ssh 2>/dev/null || true
        systemctl restart ssh 2>/dev/null || true
    ' >/dev/null 2>&1

    local ssh_state
    ssh_state="$("$WSL_EXE" -d "$DISTRO" -u root -- bash -c 'systemctl is-active ssh 2>/dev/null || echo inactive' 2>/dev/null | tr -d '\r' | head -1)"
    if [ "$ssh_state" = "active" ]; then
        ok "sshd 运行中"
    else
        err "sshd 未运行（状态: $ssh_state）"
        return 1
    fi

    # 3.3 部署密钥
    info "准备部署密钥…"
    install -d -m 700 -o jenkins -g jenkins "$JENKINS_SSH_DIR" 2>/dev/null || install -d -m 700 "$JENKINS_SSH_DIR"
    if [ ! -f "$DEPLOY_KEY" ]; then
        if [ "$(id -u)" = "0" ]; then
            ssh-keygen -t ed25519 -N '' -f "$DEPLOY_KEY" -C "jenkins@wsl-deploy" >/dev/null 2>&1
        else
            sudo ssh-keygen -t ed25519 -N '' -f "$DEPLOY_KEY" -C "jenkins@wsl-deploy" >/dev/null 2>&1
        fi
        ok "已生成 $DEPLOY_KEY"
    else
        ok "密钥已存在"
    fi
    chmod 600 "$DEPLOY_KEY"
    chown jenkins:jenkins "$DEPLOY_KEY" 2>/dev/null || true

    local pubkey
    pubkey="$(cat "$DEPLOY_KEY.pub")"
    "$WSL_EXE" -d "$DISTRO" -u root -- bash -c "
        set -e
        id $SSH_USER >/dev/null 2>&1 || useradd -m -s /bin/bash $SSH_USER
        install -d -m 700 -o $SSH_USER -g $SSH_USER /home/$SSH_USER/.ssh
        touch /home/$SSH_USER/.ssh/authorized_keys
        grep -qF '$pubkey' /home/$SSH_USER/.ssh/authorized_keys 2>/dev/null || echo '$pubkey' >> /home/$SSH_USER/.ssh/authorized_keys
        chmod 600 /home/$SSH_USER/.ssh/authorized_keys
        chown $SSH_USER:$SSH_USER /home/$SSH_USER/.ssh/authorized_keys
    " >/dev/null 2>&1 || { err "公钥授权失败"; return 1; }
    ok "公钥已授权给 $SSH_USER"

    # 3.4 target-prepare.sh
    info "执行 target-prepare.sh（装 node/nginx、建用户目录、生成 unit、配置 sudoers）…"
    if ! cat "$SCRIPT_DIR/target-prepare.sh" | "$WSL_EXE" -d "$DISTRO" -u root -- bash -s -- \
        --deploy-dir "$DEPLOY_DIR" --ssh-user "$SSH_USER" --run-user "$RUN_USER" \
        --role "$ROLE" --upstream "$UPSTREAM" 2>&1 | tail -20; then
        err "target-prepare.sh 执行失败"
        return 1
    fi
    ok "目标发行版环境已就绪"
    return 0
}

# ================================================================
# 阶段 4：打通 SSH + 写 inventory
# ================================================================
stage_ssh() {
    step "阶段 4/5  打通 SSH 免密"

    local t_ip
    t_ip="$(target_ip)"
    [ -n "$t_ip" ] || { err "读不到目标 IP"; return 1; }

    info "测试 $SSH_USER@$t_ip …"
    if timeout 10 ssh -i "$DEPLOY_KEY" \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=6 -o BatchMode=yes \
        "$SSH_USER@$t_ip" "echo ok" >/dev/null 2>&1; then
        ok "SSH 免密登录成功"
    else
        err "SSH 失败。逐项排查："
        echo "     1) sshd 状态:  wsl -d $DISTRO -- systemctl is-active ssh"
        echo "     2) 私钥权限:  ls -l $DEPLOY_KEY  (应 600, 属主 jenkins)"
        echo "     3) 授权文件:  wsl -d $DISTRO -u root -- ls -l /home/$SSH_USER/.ssh/"
        echo "     4) 网段:      本机 $(self_ip)  vs  目标 $t_ip"
        return 1
    fi

    # 写 inventory.ini
    info "写入 deploy/inventory.ini …"
    local inv="$REPO_DIR/deploy/inventory.ini"
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$inv" "$DISTRO" "$SSH_USER" "$DEPLOY_DIR" "$RUN_USER" "$ROLE" "$PORT" <<'PY'
import io, re, sys
p, distro, ssh_user, deploy_dir, run_user, role, port = sys.argv[1:8]
try:
    s = io.open(p, encoding='utf-8').read()
except FileNotFoundError:
    s = ''
block = """[%s]
host        = wsl:%s
ssh_user    = %s
deploy_dir  = %s
run_user    = %s
role        = %s
health_port = %s
enabled     = true
""" % (distro, distro, ssh_user, deploy_dir, run_user, role, port)
# 移除同名段
s = re.sub(r'^\[%s\][^\[]*' % re.escape(distro), '', s, flags=re.M)
s = s.rstrip() + '\n\n' + block
io.open(p, 'w', encoding='utf-8', newline='\n').write(s)
print('    已写入 [%s] 段' % distro)
PY
        ok "inventory.ini 已更新"
    else
        warn "没有 python3，请手工编辑 $inv"
    fi
    return 0
}

# ================================================================
# 阶段 5：试部署
# ================================================================
stage_dryrun() {
    step "阶段 5/5  试部署（dry-run，不改任何文件）"

    local ws="/var/lib/jenkins/workspace/nginx-deploy"
    if [ ! -d "$ws" ]; then
        ws="$REPO_DIR"
        warn "找不到 Jenkins workspace，改用仓库目录做演练"
    fi

    if [ "$(id -u)" = "0" ]; then
        bash "$REPO_DIR/deploy/remote-deploy.sh" "$ws" "$REPO_DIR/deploy/inventory.ini" "$DISTRO" --dry-run 2>&1 | tail -30
    else
        sudo bash "$REPO_DIR/deploy/remote-deploy.sh" "$ws" "$REPO_DIR/deploy/inventory.ini" "$DISTRO" --dry-run 2>&1 | tail -30
    fi
    return 0
}

# ================================================================
# 主流程
# ================================================================
banner

STATE="$(get_state)"
info "当前阶段: $STATE"

# 只看状态
if [ "${POSITIONAL[0]:-}" = "--status" ]; then
    echo "  阶段 $STATE"
    case "$STATE" in
        0) echo "  下一步: 阶段 1（统一网络模式）" ;;
        1) echo "  下一步: 在 Windows 执行 wsl --shutdown，然后重跑本脚本" ;;
        2) echo "  下一步: 阶段 3（准备目标发行版）" ;;
        3) echo "  下一步: 阶段 4（打通 SSH）" ;;
        4) echo "  下一步: 阶段 5（试部署）" ;;
        5) echo "  已全部完成 🎉 可在 Jenkins 勾选 REMOTE_DEPLOY 构建" ;;
    esac
    exit 0
fi

case "$STATE" in
    0)
        stage_network
        set_state 1
        echo
        echo -e "\033[1;33m  ⏭  下一步：在 Windows PowerShell 执行 \033[1mwsl --shutdown\033[0m\033[1;33m，然后重新进入本发行版再跑一次本脚本\033[0m"
        ;;
    1)
        if ! stage_check_network; then
            echo
            echo -e "\033[1;33m  ⏸  已暂停。等 wsl --shutdown 生效后重跑本脚本\033[0m"
            exit 0
        fi
        set_state 2
        echo
        echo -e "\033[1;33m  ⏭  下一步：重跑本脚本（将进入阶段 3，准备目标发行版）\033[0m"
        ;;
    2)
        stage_prepare || exit 1
        set_state 3
        echo
        echo -e "\033[1;33m  ⏭  下一步：重跑本脚本（将进入阶段 4，打通 SSH）\033[0m"
        ;;
    3)
        stage_ssh || exit 1
        set_state 4
        echo
        echo -e "\033[1;33m  ⏭  下一步：重跑本脚本（将进入阶段 5，试部署）\033[0m"
        ;;
    4)
        stage_dryrun
        set_state 5
        echo
        echo -e "\033[1;32m  🎉 全部完成！\033[0m"
        cat << EOF

  现在可以在 Jenkins 里：
    1. 打开流水线任务 → 「Build with Parameters」
    2. 勾选 REMOTE_DEPLOY = true
    3. TARGET_HOSTS 填 $DISTRO（或留空 = 全部）
    4. 先勾 DRY_RUN 演练一次，确认无误后再正式构建

  也可以命令行直接部署：
    sudo -u jenkins bash $REPO_DIR/deploy/remote-deploy.sh \\
        /var/lib/jenkins/workspace/nginx-deploy \\
        $REPO_DIR/deploy/inventory.ini $DISTRO

  查看进度： bash $SCRIPT_DIR/wsl-setup-all.sh --status

EOF
        ;;
    5)
        echo -e "\033[1;32m  ✔ 已全部完成，无需再跑。\033[0m"
        echo "  如需重置进度，删除状态文件： rm -f $STATE_FILE"
        ;;
esac
