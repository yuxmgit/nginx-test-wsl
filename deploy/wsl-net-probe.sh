#!/bin/bash
#
# WSL 发行版间连通性诊断（在 Jenkins 所在的 WSL 发行版内运行）
#
# 目的：搞清「Jenkins 发行版 → 目标发行版」到底该用哪个地址连。
# 本脚本只做探测和测试，不修改任何配置。
#
# 用法：bash deploy/wsl-net-probe.sh [目标发行版名]
# 默认目标发行版：Ubuntu-24.04
#
set -uo pipefail

TARGET="${1:-Ubuntu-24.04}"
WSL_EXE="/mnt/c/Windows/System32/wsl.exe"

hr()  { echo "------------------------------------------------------------"; }
log() { echo; echo "=== $* ==="; }
ok()  { echo -e "  \033[1;32m[OK]\033[0m $*"; }
bad() { echo -e "  \033[1;31m[NG]\033[0m $*"; }
inf() { echo "  $*"; }

echo "=================================================="
echo " WSL 发行版连通性诊断"
echo " 诊断者: $(hostname)  (IP: $(ip -4 addr show eth0 2>/dev/null | grep -oP 'inet \K[\d.]+' || echo '?'))"
echo " 目标   : $TARGET"
echo "=================================================="

# ---------- 0. interop 检查 ----------
log "0. Windows interop 可用性"
if [ -x "$WSL_EXE" ]; then
    ok "找到 $WSL_EXE"
else
    bad "找不到 $WSL_EXE —— 请确认在 WSL 发行版内运行（不是 Git Bash）"
    exit 1
fi

# ---------- 1. 本发行版网络 ----------
log "1. 本发行版（Jenkins 所在）网络"
ip -4 addr show 2>/dev/null | grep -E "inet |^[0-9]+:" | sed 's/^/  /'
echo "  --- 路由表 ---"
ip route 2>/dev/null | sed 's/^/  /'

# ---------- 2. 目标发行版网络 ----------
log "2. 目标发行版 $TARGET 的网络"
if ! "$WSL_EXE" -d "$TARGET" -- echo ok >/dev/null 2>&1; then
    bad "无法进入发行版 $TARGET（可能未运行）"
    echo "  请在 Windows 执行: wsl -d $TARGET"
    exit 1
fi
ok "可以进入 $TARGET"

TARGET_IPS="$("$WSL_EXE" -d "$TARGET" -- hostname -I 2>/dev/null | tr -d '\r' | xargs)"
inf "hostname -I : ${TARGET_IPS:-（空）}"

echo "  --- 网卡详情 ---"
"$WSL_EXE" -d "$TARGET" -- ip -4 addr show 2>/dev/null | tr -d '\r' | grep -E "inet |^[0-9]+:" | sed 's/^/  /'

echo "  --- 路由表 ---"
"$WSL_EXE" -d "$TARGET" -- ip route 2>/dev/null | tr -d '\r' | sed 's/^/  /'

echo "  --- 网卡命名与模式 ---"
"$WSL_EXE" -d "$TARGET" -- ip -br addr 2>/dev/null | tr -d '\r' | sed 's/^/  /'

PRIMARY_IP="$(echo "$TARGET_IPS" | awk '{print $1}')"

# ---------- 3. 可达性矩阵 ----------
log "3. 从本发行版测试各候选地址"
CANDIDATES=""
for ip in $TARGET_IPS; do CANDIDATES="$CANDIDATES $ip"; done
# 也试试目标机上常见的 WSL NAT 地址段
for probe_ip in $(ip -4 addr show eth0 2>/dev/null | grep -oP 'inet \K[\d.]+' | sed 's/\.[0-9]*$//'); do
    for last in 11 12 13 14 15 16 17 18 19 20 21 22; do
        CANDIDATES="$CANDIDATES $probe_ip.$last"
    done
done

REACHABLE=""
for ip in $CANDIDATES; do
    # ping 测试
    PING_OK="no"
    ping -c 1 -W 1 "$ip" >/dev/null 2>&1 && PING_OK="yes"
    # TCP 22 测试
    TCP_OK="no"
    if timeout 2 bash -c "</dev/tcp/$ip/22" 2>/dev/null; then TCP_OK="yes"; fi
    if [ "$PING_OK" = "yes" ] || [ "$TCP_OK" = "yes" ]; then
        ok "$ip  ping=$PING_OK  tcp22=$TCP_OK"
        [ "$TCP_OK" = "yes" ] && REACHABLE="$REACHABLE $ip"
    else
        inf "$ip  ping=$PING_OK  tcp22=$TCP_OK"
    fi
done
[ -n "$REACHABLE" ] || inf "（没有发现 22 端口可达的地址）"

# ---------- 4. sshd 状态 ----------
log "4. 目标发行版 sshd 状态"
SSHD_STATE="$("$WSL_EXE" -d "$TARGET" -u root -- bash -c 'systemctl is-active ssh 2>/dev/null || systemctl is-active sshd 2>/dev/null || echo "not-installed"' 2>/dev/null | tr -d '\r' | head -1)"
inf "sshd 状态: $SSHD_STATE"
if [ "$SSHD_STATE" != "active" ]; then
    inf "→ 需要执行 deploy/wsl-second-node.sh 来安装并启用 sshd"
fi

# ---------- 5. 代理通道可行性 ----------
log "5. 测试 wsl.exe 代理通道（跨网段时的兜底方案）"
# 若目标发行版有 sshd，可以通过 wsl.exe 把 SSH 流量管道进目标发行版
PROXY_TEST="$("$WSL_EXE" -d "$TARGET" -u root -- bash -c 'command -v nc >/dev/null && echo "nc-ok" || echo "nc-missing"' 2>/dev/null | tr -d '\r' | head -1)"
inf "目标发行版内 nc: $PROXY_TEST"

# ---------- 6. 结论 ----------
echo
echo "=================================================="
echo " 诊断结论"
echo "=================================================="
echo "  本发行版 IP   : $(ip -4 addr show eth0 2>/dev/null | grep -oP 'inet \K[\d.]+' | head -1)"
echo "  目标发行版 IP : ${PRIMARY_IP:-未知}"
echo "  sshd 状态     : $SSHD_STATE"
echo "  22端口可达    : ${REACHABLE:-（无）}"
echo "=================================================="

if [ -n "$REACHABLE" ]; then
cat <<EOF

 ✅ 直连可用。inventory.ini 里 host 写：

    [$TARGET]
    host        = ${REACHABLE%% *}
    ssh_user    = deploy
    deploy_dir  = /srv/nginx-project
    run_user    = appuser
    role        = full
    health_port = 80
    enabled     = true

 （也可以写 wsl:$TARGET 让脚本动态解析，但直连 IP 更直观）

EOF
elif [ "$SSHD_STATE" = "active" ]; then
cat <<EOF

 ⚠️ sshd 已启动，但本发行版无法直连目标机的 22 端口。
    两个发行版处于不同网段（跨网段被隔离）。

 解决办法（推荐，最简单）：统一网络模式
   1. 编辑 C:\\Users\\yuxiangming\\.wslconfig，改为：
        [wsl2]
        memory=6GB
        processors=4
        swap=4GB
        localhostForwarding=true
        dnsTunneling=true
        firewall=true
        networkingMode=nat
   2. 在 Windows PowerShell 执行：
        wsl --shutdown
   3. 重新进入两个发行版，再跑本脚本
   → 两发行版就会拿到同一个 172.18.32.x 网段的地址，直连即可。

EOF
else
cat <<EOF

 ⚠️ 目标发行版还没装/启 sshd。

 先执行：
    bash deploy/wsl-second-node.sh --distro $TARGET
 它会安装 sshd、启用 systemd、配置免密密钥、准备部署目录，
 完成后再跑本脚本复测连通性。

EOF
fi
