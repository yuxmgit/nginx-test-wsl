#!/bin/bash
#
# WSL 网络模式统一脚本（宿主机上执行，或从任一发行版内调用 wsl.exe 执行）
#
# 问题：不同 WSL 发行版可能处于不同网络模式
#   - NAT 模式（默认）：发行版地址在 172.18.x.x/20
#   - mirrored 模式：发行版直接用宿主机的局域网 IP
#   混合模式下，NAT 的发行版无法主动访问 mirrored 的发行版（跨网段隔离），
#   导致 Jenkins → 目标机的 SSH 必然超时。
#
# 解决：把所有发行版统一为 NAT 模式，然后 wsl --shutdown 重启。
#
# 用法（在 Windows PowerShell 里执行，需管理员权限）：
#   wsl --shutdown
#   # 然后手动改 .wslconfig，或用本脚本
#
# 本脚本会：
#   1. 备份现有 .wslconfig
#   2. 写入/更新 networkingMode=nat
#   3. 提示你执行 wsl --shutdown
#
# 备选方案（不动网络模式）：把目标发行版的 sshd 端口通过 Windows 端口转发暴露，
#   但配置更繁琐，一般优先统一网络模式。
#
set -euo pipefail

WSL_EXE="/mnt/c/Windows/System32/wsl.exe"
WIN_HOME="${WIN_HOME:-$(cmd.exe /c echo %USERPROFILE% 2>/dev/null | tr -d '\r' | sed 's|\\|/|g')}"
WSLCONF="$WIN_HOME/.wslconfig"

log()  { echo -e "\n\033[1;36m==> $*\033[0m"; }
ok()   { echo -e "\033[1;32m[ok]\033[0m $*"; }
warn() { echo -e "\033[1;33m[warn]\033[0m $*"; }
die()  { echo -e "\033[1;31m[fail]\033[0m $*" >&2; exit 1; }

log "当前 .wslconfig"
if [ -f "$WSLCONF" ]; then
    cat "$WSLCONF"
else
    warn "文件不存在，将新建"
fi

log "备份"
if [ -f "$WSLCONF" ]; then
    cp "$WSLCONF" "$WSLCONF.bak.$(date +%Y%m%d-%H%M%S)"
    ok "已备份到 $WSLCONF.bak.*"
fi

log "写入 networkingMode=nat"
# 用 python 处理，避免 sed 的 BOM/换行问题
if command -v python3 >/dev/null 2>&1; then
    python3 - "$WSLCONF" <<'PY'
import io, re, sys
p = sys.argv[1]
try:
    s = io.open(p, encoding='utf-8-sig').read()
except FileNotFoundError:
    s = '[wsl2]\n'
s = re.sub(r'^[ \t]*networkingMode[ \t]*=.*$', '', s, flags=re.M)
s = re.sub(r'\n{3,}', '\n\n', s).strip('\n')
lines = s.split('\n')
out, in_wsl2, inserted = [], False, False
for ln in lines:
    st = ln.strip()
    if st.startswith('['):
        if in_wsl2 and not inserted:
            out.append('networkingMode=nat')
            inserted = True
        in_wsl2 = (st == '[wsl2]')
    out.append(ln)
if in_wsl2 and not inserted:
    out.append('networkingMode=nat')
io.open(p, 'w', encoding='utf-8-sig', newline='\n').write('\n'.join(out) + '\n')
print("已写入 networkingMode=nat")
PY
else
    die "没有 python3，请手工编辑 $WSLCONF"
fi

echo
cat "$WSLCONF"

cat << EOF

============================================================
 接下来必须执行（这一步不能省）
============================================================

 在 Windows PowerShell 中：

    wsl --shutdown

 然后重新进入两个发行版，确认 IP 变成同一网段：

    wsl -d Ubuntu -- ip -4 addr show eth0
    wsl -d Ubuntu-24.04 -- ip -4 addr show eth0

 两者都应是 172.18.x.x 开头。

 再验证连通性（任意一个发行版内）：

    bash deploy/wsl-net-probe.sh Ubuntu-24.04

 最后重跑准备脚本：

    bash deploy/wsl-second-node.sh --distro Ubuntu-24.04

============================================================

EOF
