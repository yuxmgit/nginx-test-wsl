#!/bin/bash
#
# Jenkins 自动触发诊断脚本
#
# 用途：检查"git push → Jenkins 自动构建"链路上的每个环节，快速定位断在哪
# 用法（WSL Ubuntu 里执行）：
#   bash deploy/jenkins-diagnose.sh                    # 只诊断，不修改
#   bash deploy/jenkins-diagnose.sh --trigger          # 诊断 + 手动触发一次构建
#
# 可选环境变量：
#   JENKINS_URL      Jenkins 地址（默认 http://localhost:8080）
#   JENKINS_USER     Jenkins 用户名（配置了 API Token 时需要）
#   JENKINS_TOKEN    Jenkins API Token（手动触发构建时需要）
#   JENKINS_JOB      任务名（默认 nginx-deploy）
#
set -uo pipefail

JENKINS_URL="${JENKINS_URL:-http://localhost:8080}"
JENKINS_JOB="${JENKINS_JOB:-nginx-deploy}"
TRIGGER_NOW=0
[ "${1:-}" = "--trigger" ] && TRIGGER_NOW=1

c_ok=""; c_err=""; c_warn=""; c_dim=""; c_end=""
if [ -t 1 ]; then
    c_ok=$'\033[1;32m'; c_err=$'\033[1;31m'; c_warn=$'\033[1;33m'; c_dim=$'\033[2m'; c_end=$'\033[0m'
fi
ok()   { echo "${c_ok}[ok]${c_end} $*"; }
err()  { echo "${c_err}[fail]${c_end} $*"; }
warn() { echo "${c_warn}[warn]${c_end} $*"; }
info() { echo "       $*"; }

# 构造 curl 的认证参数
if [ -n "${JENKINS_TOKEN:-}" ] && [ -n "${JENKINS_USER:-}" ]; then
    AUTH=(-u "${JENKINS_USER}:${JENKINS_TOKEN}")
    echo "使用 API Token 认证"
else
    AUTH=()
    echo "${c_dim}未配置 JENKINS_USER/JENKINS_TOKEN，仅做匿名检查（多数操作会 403）${c_end}"
fi

echo ""
echo "=================================================="
echo " Jenkins 自动触发诊断"
echo "=================================================="
echo " Jenkins: $JENKINS_URL"
echo " 任务:    $JENKINS_JOB"
echo "=================================================="

# ---------- 1. Jenkins 服务 ----------
echo ""
echo "1) Jenkins 服务状态"
if command -v systemctl >/dev/null && systemctl list-unit-files 2>/dev/null | grep -q jenkins; then
    if systemctl is-active --quiet jenkins; then
        ok "jenkins 服务运行中"
    else
        err "jenkins 服务未运行（sudo systemctl start jenkins）"
    fi
else
    warn "未检测到 systemd jenkins 服务（非 WSL 环境？）"
fi

if curl -s -o /dev/null --max-time 5 "$JENKINS_URL" 2>/dev/null; then
    ok "Jenkins HTTP 可达"
else
    err "Jenkins 无法访问：$JENKINS_URL"
    echo "  排查：sudo systemctl status jenkins / sudo journalctl -u jenkins -n 50"
    exit 1
fi

# ---------- 2. 任务是否存在 ----------
echo ""
echo "2) 任务是否存在"
JOB_API="$JENKINS_URL/job/$JENKINS_JOB/api/json"
JOB_CODE=$(curl -s -o /tmp/_job.json -w '%{http_code}' --max-time 8 "${AUTH[@]}" "$JOB_API" 2>/dev/null)
case "$JOB_CODE" in
    200)
        ok "任务 '$JENKINS_JOB' 存在"
        if command -v python3 >/dev/null; then
            python3 - << PY 2>/dev/null
import json
try:
    d = json.load(open('/tmp/_job.json'))
    print(f"       最后构建: #{d.get('lastBuild',{}).get('number','无')}")
    print(f"       结果:     {d.get('lastBuild',{}).get('result','无')}")
    print(f"       是否可构建: {d.get('buildable','未知')}")
    print(f"       触发器:   {d.get('triggers',[])}")
except Exception as e:
    pass
PY
        fi
        ;;
    403|401)
        err "任务存在但需要认证（HTTP $JOB_CODE）——请设置 JENKINS_USER / JENKINS_TOKEN"
        ;;
    404)
        err "任务 '$JENKINS_JOB' 不存在（HTTP 404）"
        info "请在 Jenkins 首页 New Item 创建一个名为 '$JENKINS_JOB' 的 Pipeline 任务"
        ;;
    *)
        err "查询任务返回 HTTP $JOB_CODE"
        ;;
esac

# ---------- 3. 触发器配置 ----------
echo ""
echo "3) 构建触发器配置"
CFG_XML="/tmp/_job_config.xml"
CFG_CODE=$(curl -s -o "$CFG_XML" -w '%{http_code}' --max-time 8 "${AUTH[@]}" \
           "$JENKINS_URL/job/$JENKINS_JOB/config.xml" 2>/dev/null)
if [ "$CFG_CODE" = "200" ]; then
    if grep -q "GitHubPushTrigger\|github" "$CFG_XML" 2>/dev/null; then
        ok "检测到 GitHub hook 触发器"
    fi
    if grep -q "hudson.triggers.SCMTrigger\|<spec>" "$CFG_XML" 2>/dev/null; then
        ok "检测到 Poll SCM（轮询）触发器"
        grep -oP '<spec>\K[^<]+' "$CFG_XML" 2>/dev/null | sed 's/^/       轮询表达式: /'
    fi
    if ! grep -q "GitHubPushTrigger\|hudson.triggers.SCMTrigger" "$CFG_XML" 2>/dev/null; then
        warn "未检测到任何自动触发器 —— 任务只能手动点 Build Now"
        info "去任务页 → Configure → Build Triggers 勾选触发器"
    fi
    # 分支配置
    if grep -oP '<name>\K[^<]+' "$CFG_XML" 2>/dev/null | head -3 | grep -q .; then
        info "分支配置:"
        grep -oP '<name>\K[^<]+' "$CFG_XML" 2>/dev/null | head -3 | sed 's/^/         /'
    fi
elif [ "$CFG_CODE" = "403" ] || [ "$CFG_CODE" = "401" ]; then
    warn "无法读取任务配置（需要认证）"
else
    warn "读取 config.xml 返回 HTTP $CFG_CODE"
fi

# ---------- 4. GitHub 连通性 ----------
echo ""
echo "4) Jenkins → GitHub 连通性（决定 Poll SCM 能否工作）"
if curl -s -o /dev/null --max-time 10 https://github.com 2>/dev/null; then
    ok "GitHub 可直连"
else
    warn "GitHub 直连失败，Jenkins 拉代码会超时"
    info "WSL 里需要单独配代理（Windows 的代理不会自动生效）："
    info "  export https_proxy=http://\$(ip route show default | awk '{print \$3}'):7890"
    info "  并写入 ~/.bashrc，同时给 apt 配 /etc/apt/apt.conf.d/99proxy"
fi

# ---------- 5. 手动触发测试 ----------
echo ""
echo "5) 手动触发构建测试"
if [ "$TRIGGER_NOW" != "1" ]; then
    info "加 --trigger 参数可实际触发一次构建"
else
    if [ -z "${JENKINS_TOKEN:-}" ]; then
        err "未设置 JENKINS_TOKEN，无法触发"
        info "生成 API Token：Jenkins 右上角头像 → Security → API Token → Generate new token"
        info "然后：export JENKINS_USER=你的用户名 JENKINS_TOKEN=ghp_xxx"
    else
        # 取 CSRF crumb
        CRUMB=$(curl -s --max-time 8 "${AUTH[@]}" "$JENKINS_URL/crumbIssuer/api/json" 2>/dev/null \
                | grep -oP '"crumb"\s*:\s*"\K[^"]+')
        CRUMB_HEADER=""
        [ -n "$CRUMB" ] && CRUMB_HEADER="-H"
        BUILD_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
                     "${AUTH[@]}" -X POST \
                     ${CRUMB:+$CRUMB_HEADER "$CRUMB"} \
                     "$JENKINS_URL/job/$JENKINS_JOB/build" 2>/dev/null)
        if [ "$BUILD_CODE" = "201" ] || [ "$BUILD_CODE" = "200" ]; then
            ok "构建已触发（HTTP $BUILD_CODE），去 Jenkins 页面看 Console Output"
        else
            err "触发失败（HTTP $BUILD_CODE）"
            info "201/200 = 成功；403 = 权限或 CSRF 问题；404 = 任务名不对"
        fi
    fi
fi

# ---------- 6. Webhook 状态（如果手动创建过）----------
echo ""
echo "6) GitHub Webhook 状态"
if command -v gh >/dev/null; then
    if gh auth status >/dev/null 2>&1; then
        HOOKS=$(gh api "repos/yuxmgit/nginx-test-wsl/hooks" --jq 'length' 2>/dev/null || echo "?")
        info "仓库现有 webhook 数量: $HOOKS"
        gh api "repos/yuxmgit/nginx-test-wsl/hooks" --jq '.[] | "  id=\(.id) url=\(.config.url) active=\(.active)"' 2>/dev/null
    else
        warn "未安装 gh 或未登录 GitHub，跳过 webhook 检查"
    fi
else
    warn "未安装 gh CLI，跳过 webhook 检查（可手动到仓库 Settings → Webhooks 查看）"
fi

echo ""
echo "=================================================="
echo " 诊断结束"
echo "=================================================="
echo ""
echo "根据上面的结果选择方案："
echo "  · 第 3 项显示无触发器  → 方案 A：Poll SCM（5 分钟搞定）"
echo "  · 第 4 项显示 GitHub 不通 → 先修代理，否则轮询也会失败"
echo "  · 想实时触发           → 方案 B：ngrok 隧道 / 方案 C：自托管 Runner"
echo ""
echo "详细步骤见 deploy/jenkins-auto-trigger.md"
echo ""
