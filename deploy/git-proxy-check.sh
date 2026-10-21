#!/bin/bash
#
# GitHub 连通性诊断 + 代理配置脚本
#
# 用法：
#   bash deploy/git-proxy-check.sh          # 仅诊断
#   bash deploy/git-proxy-check.sh --set 7890   # 诊断并配置代理（端口号自定）
#   bash deploy/git-proxy-check.sh --unset  # 清除 Git 代理配置
#
# 目的：解决 git push 时的
#   fatal: unable to access '...': CONNECT tunnel failed, response 502
#
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REMOTE="origin"

c_ok=""; c_err=""; c_warn=""; c_dim=""; c_end=""
if [ -t 1 ]; then
    c_ok=$'\033[1;32m'; c_err=$'\033[1;31m'; c_warn=$'\033[1;33m'; c_dim=$'\033[2m'; c_end=$'\033[0m'
fi

ok()   { echo "${c_ok}[ok]${c_end} $*"; }
err()  { echo "${c_err}[fail]${c_end} $*"; }
warn() { echo "${c_warn}[warn]${c_end} $*"; }
info() { echo "${c_dim}       $*${c_end}"; }

echo ""
echo "=================================================="
echo " GitHub 连通性诊断"
echo "=================================================="

# ---------- 1. 当前 Git 代理配置 ----------
echo ""
echo "1) 当前 Git 代理配置"
PROXY_HTTP="$(git config --global --get http.proxy 2>/dev/null || true)"
PROXY_HTTPS="$(git config --global --get https.proxy 2>/dev/null || true)"
if [ -n "$PROXY_HTTP" ] || [ -n "$PROXY_HTTPS" ]; then
    ok "已配置： http.proxy  = ${PROXY_HTTP:-（空）}"
    ok "         https.proxy = ${PROXY_HTTPS:-（空）}"
else
    warn "未配置 Git 代理"
fi

# ---------- 2. 端口探测 ----------
echo ""
echo "2) 常见代理端口探测"
FOUND=""
for p in 7890 7897 7891 10809 10808 1080 8888 20171 33210 1081 8080 8118; do
    if timeout 2 bash -c "cat < /dev/null > /dev/tcp/127.0.0.1/$p" 2>/dev/null; then
        ok "端口 $p 正在监听"
        FOUND="$FOUND $p"
    fi
done
if [ -z "$FOUND" ]; then
    err "没有发现任何常见代理端口在监听"
    echo ""
    echo "  >>> 请先启动你的代理软件（Clash / V2Ray / Verge / Shadowsocks 等）"
    echo "  >>> 启动后重新运行本脚本"
    echo ""
    exit 1
fi

# ---------- 3. 用代理测试 ----------
echo ""
echo "3) 通过代理测试 GitHub"
TEST_PORT="$(echo $FOUND | awk '{print $1}')"
if curl -s -o /dev/null -w '' --max-time 10 \
     --proxy "http://127.0.0.1:$TEST_PORT" https://github.com 2>/dev/null; then
    ok "代理 http://127.0.0.1:$TEST_PORT 可访问 GitHub"
else
    err "代理 http://127.0.0.1:$TEST_PORT 无法访问 GitHub"
    echo "     可能是代理软件节点不可用，换个节点再试"
    exit 1
fi

# ---------- 4. 处理参数 ----------
case "${1:-}" in
    --set)
        PORT="${2:-$TEST_PORT}"
        echo ""
        echo "4) 配置 Git 代理（仓库级，不影响其他仓库）"
        cd "$REPO_DIR" || exit 1
        git config --local http.proxy  "http://127.0.0.1:$PORT"
        git config --local https.proxy "http://127.0.0.1:$PORT"
        ok "已设置 http.proxy / https.proxy = http://127.0.0.1:$PORT"
        ;;
    --unset)
        echo ""
        echo "4) 清除 Git 代理配置"
        cd "$REPO_DIR" || exit 1
        git config --local --unset http.proxy  2>/dev/null || true
        git config --local --unset https.proxy 2>/dev/null || true
        git config --global --unset http.proxy  2>/dev/null || true
        git config --global --unset https.proxy 2>/dev/null || true
        ok "已清除全部代理配置"
        ;;
esac

# ---------- 5. 最终验证 ----------
echo ""
echo "5) 验证远程仓库连通性"
cd "$REPO_DIR" || exit 1
if git ls-remote "$REMOTE" 2>&1 | head -5; then
    echo ""
    ok "仓库可达，可以执行： git push -u $REMOTE main"
    exit 0
else
    echo ""
    err "仓库仍不可达"
    echo ""
    echo "  排查方向："
    echo "   1. 代理软件是否真的能访问 github.com（浏览器打开 https://github.com 试试）"
    echo "   2. 端口是否正确（看代理软件界面的 HTTP 端口，不是 SOCKS 端口）"
    echo "   3. 是否需要用 SOCKS5：git config --global http.proxy socks5h://127.0.0.1:$PORT"
    exit 1
fi
