#!/bin/bash
#
# lab-troubleshoot.sh —— 故障注入与还原实验脚本
#
# 用途：亲手把本项目的 Nginx + Node 后端搞坏，然后按《Ubuntu故障排查实战.md》
#      的流程一步步捞回来。每一个场景都对应手册里的一个排查章节。
#
# 用法：
#   bash deploy/lab-troubleshoot.sh list                    # 列出所有场景
#   bash deploy/lab-troubleshoot.sh doctor                  # 环境体检
#   bash deploy/lab-troubleshoot.sh inject <场景>            # 注入故障
#   bash deploy/lab-troubleshoot.sh restore                 # 还原全部
#   bash deploy/lab-troubleshoot.sh answer <场景>            # 看参考答案
#   bash deploy/lab-troubleshoot.sh status                  # 看当前注入状态
#
# ⚠️ 请在 WSL / 测试机上演练。不要在生产服务器上运行 inject。

set -u

PROJECT_DIR="${PROJECT_DIR:-$HOME/nginx-project}"
BACKUP_DIR="$PROJECT_DIR/.lab-backup"
STATE_FILE="$PROJECT_DIR/.lab-state"
NGINX_SITE="/etc/nginx/sites-available/nginx-app"
NGINX_LINK="/etc/nginx/sites-enabled/nginx-app"
NGINX_CONF="/etc/nginx/nginx.conf"
LOG_DIR="$PROJECT_DIR/logs"

RED='\033[1;31m'; GREEN='\033[1;32m'; YELLOW='\033[1;33m'
CYAN='\033[1;36m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${CYAN}[信息]${NC} $*"; }
ok()    { echo -e "${GREEN}[完成]${NC} $*"; }
warn()  { echo -e "${YELLOW}[警告]${NC} $*"; }
die()   { echo -e "${RED}[错误]${NC} $*" >&2; exit 1; }
title() { echo -e "\n${BOLD}$*${NC}"; }

need_root() {
  [ "$(id -u)" -eq 0 ] || die "此操作需要 sudo，请用：sudo bash $0 $*"
}

# ---------------------------------------------------------------
# 环境体检
# ---------------------------------------------------------------
cmd_doctor() {
  title "环境体检"
  local problems=0

  info "检查平台"
  if [ "$(uname -s)" != "Linux" ]; then
    warn "当前系统是 $(uname -s)，此脚本应在 Linux/WSL 下运行"
  else
    echo "    平台：Linux $(uname -r)"
  fi

  info "检查 systemd"
  if [ "$(ps -p 1 -o comm= 2>/dev/null)" = "systemd" ]; then
    echo "    systemd 已启用"
  else
    warn "systemd 未启用，部分场景（restart-loop）无法演练"
    problems=$((problems+1))
  fi

  info "检查 Node"
  if command -v node >/dev/null; then
    echo "    Node：$(node -v)  ($(command -v node))"
  else
    warn "未安装 Node.js"
    problems=$((problems+1))
  fi

  info "检查 Nginx"
  if command -v nginx >/dev/null; then
    echo "    Nginx：$(nginx -v 2>&1)"
  else
    warn "未安装 Nginx，请先执行：sudo apt update && sudo apt install -y nginx"
    problems=$((problems+1))
  fi

  info "检查项目目录"
  if [ -d "$PROJECT_DIR" ]; then
    echo "    项目：$PROJECT_DIR"
    ls -1 "$PROJECT_DIR" 2>/dev/null | sed 's/^/      - /'
  else
    warn "项目目录不存在：$PROJECT_DIR"
    echo "    请先执行：bash deploy/deploy.sh"
    problems=$((problems+1))
  fi

  info "检查 Nginx 站点配置"
  if sudo test -f "$NGINX_SITE" 2>/dev/null; then
    echo "    站点配置存在"
  else
    warn "未找到 $NGINX_SITE，请先执行 deploy.sh"
    problems=$((problems+1))
  fi

  title "当前服务状态"
  systemctl --no-pager --lines=0 status nginx 2>/dev/null | head -4 | sed 's/^/  /' || echo "  nginx: 未运行"
  systemctl --no-pager --lines=0 status api-server1 2>/dev/null | head -4 | sed 's/^/  /' || echo "  api-server1: 未运行"
  systemctl --no-pager --lines=0 status api-server2 2>/dev/null | head -4 | sed 's/^/  /' || echo "  api-server2: 未运行"

  title "端口监听"
  ss -tlnp 2>/dev/null | grep -E ':80|:4001|:4002' | sed 's/^/  /' || echo "  相关端口未监听"

  title "资源概况"
  free -h | sed 's/^/  /'
  df -h / | tail -1 | sed 's/^/  /'

  echo
  if [ "$problems" -eq 0 ]; then
    ok "环境就绪，可以开始练习了。先跑：bash $0 list"
  else
    warn "发现 $problems 个问题，请先处理后再演练"
  fi
}

# ---------------------------------------------------------------
# 备份与状态
# ---------------------------------------------------------------
do_backup() {
  mkdir -p "$BACKUP_DIR" 2>/dev/null || true
  sudo mkdir -p "$BACKUP_DIR" 2>/dev/null || true
  sudo cp -a "$NGINX_SITE" "$BACKUP_DIR/nginx-app.conf.bak" 2>/dev/null || true
  sudo cp -a "$NGINX_CONF" "$BACKUP_DIR/nginx.conf.bak" 2>/dev/null || true
  sudo cp -a /etc/systemd/system/api-server1.service "$BACKUP_DIR/api-server1.service.bak" 2>/dev/null || true
  [ -f /etc/systemd/system/api-server2.service ] && \
    sudo cp -a /etc/systemd/system/api-server2.service "$BACKUP_DIR/api-server2.service.bak" 2>/dev/null || true
  [ -f "$LOG_DIR/server2.log" ] && sudo cp -a "$LOG_DIR/server2.log" "$BACKUP_DIR/" 2>/dev/null || true
  ok "已备份配置到 $BACKUP_DIR"
}

set_state() { echo "$1" | sudo tee "$STATE_FILE" >/dev/null 2>&1; }
get_state() { sudo cat "$STATE_FILE" 2>/dev/null || echo "none"; }

# ---------------------------------------------------------------
# 故障场景实现
# ---------------------------------------------------------------

# 场景 1：upstream 端口写错 → 502
inject_502() {
  do_backup
  title "注入故障：502 Bad Gateway"
  echo "把 upstream 里 server2 的端口从 4002 改成 4999（一个没人监听的端口）"

  sudo cp -a "$NGINX_CONF" "$NGINX_CONF.lab.bak" 2>/dev/null || true
  sudo sed -i 's|127\.0\.0\.1:4002;|127.0.0.1:4999;|' "$NGINX_CONF"

  if sudo nginx -t >/dev/null 2>&1; then
    sudo systemctl reload nginx
    ok "Nginx 已重载"
  else
    warn "Nginx 配置检查失败，尝试重新加载"
    sudo systemctl reload nginx 2>/dev/null || sudo systemctl restart nginx
  fi

  echo
  echo "现在访问 http://localhost/api/user 会得到 502。"
  echo "请按《Ubuntu故障排查实战.md》第 3.1 节的步骤排查。"
  echo "排查完执行：sudo bash $0 restore"
  set_state 502
}

# 场景 2：磁盘写满
inject_disk() {
  do_backup
  title "注入故障：磁盘写满"
  local size="${1:-2G}"
  local filler="/var/tmp/lab-filler-$$.dat"

  # 解析出可用空间的字节数，并算出注入后剩余百分比
  local avail_kb avail_mb avail_gb
  avail_kb=$(df -k / | awk 'NR==2 {print $4}')
  [ -n "$avail_kb" ] || { die "无法读取磁盘可用空间"; }

  echo "将创建填充文件把磁盘占满："
  echo "  文件：$filler"
  echo "  大小：$size"
  echo
  df -h / | tail -1 | sed 's/^/  当前：/'
  echo

  #安全阀：注入后可用空间不得低于 10%，否则可能把自己系统写挂
  avail_mb=$((avail_kb / 1024))
  avail_gb=$((avail_mb / 1024))
  if [ "$size" = "2G" ] && [ "$avail_gb" -lt 6 ]; then
    die "磁盘可用空间只有 ${avail_gb}G，注入 2G 可能影响系统
如需继续请显式指定更小的值：inject disk 500M"
  fi
  if [ "$size" = "2G" ]; then
    echo "  ⚠️  默认注入 2G。想更温和一点可以用：inject disk 500M"
  fi
  echo
  read -rp "  确认继续？(yes/no) " ans
  [ "$ans" = "yes" ] || { info "已取消"; return; }

  # fallocate 真实分配磁盘块（truncate 只建稀疏文件，不占空间）
  if ! sudo fallocate -l "$size" "$filler" 2>/dev/null; then
    warn "fallocate 不可用，改用 dd 写入"
    sudo dd if=/dev/zero of="$filler" bs=1M count=2048 status=none
  fi

  ok "已创建填充文件"
  sudo ls -lh "$filler" | sed 's/^/  /'
  echo "  当前磁盘："
  df -h / | tail -1 | sed 's/^/    /'

  printf '%s' "$filler" | sudo tee "$STATE_FILE.disk" >/dev/null 2>&1
  set_state disk

  echo
  echo "请按《Ubuntu故障排查实战.md》第 3.5 节排查。"
  echo "  重点命令：df -h / && df -i /"
  echo "  sudo du -h --max-depth=1 /var 2>/dev/null | sort -rh | head"
  echo "  sudo find / -xdev -type f -size +500M 2>/dev/null"
  echo "排查完执行：sudo bash $0 restore"
}

# 场景 3：内存飙升（不必然触发 OOM，但足以让 free/available 明显下降）
inject_oom() {
  title "注入故障：内存占用飙升"
  local mem="${1:-512}"
  echo "启动一个占用约 ${mem}MB 常驻内存的进程"
  echo

  free -h | sed 's/^/  当前：/'
  echo
  read -rp "  确认继续？(yes/no) " ans
  [ "$ans" = "yes" ] || { info "已取消"; return; }

  # 必须真正持有内存（不能写到 /dev/null），否则测不出效果
  if command -v python3 >/dev/null; then
    nohup python3 -c "
import time
buf = bytearray($((mem * 1024 * 1024)))   # 真正分配 $mem MB
for i in range(0, len(buf), 4096):
    buf[i] = 65                            # 逐页写入，确保物理页被分配
time.sleep(3600)
" > /var/tmp/lab-oom.log 2>&1 &
  elif command -v node >/dev/null; then
    nohup node -e "
const buf = Buffer.alloc($((mem * 1024 * 1024)), 65);  // 真正分配并写入
setInterval(() => { buf[0] = 66; }, 60000);
" > /var/tmp/lab-oom.log 2>&1 &
  else
    die "需要 python3 或 node 才能执行此场景"
  fi

  local pid=$!
  sleep 2
  printf '%s' "$pid" | sudo tee "$STATE_FILE.oom" >/dev/null 2>&1

  if kill -0 "$pid" 2>/dev/null; then
    ok "内存占用进程已启动，PID $pid"
  else
    warn "进程启动失败，日志："
    sudo tail -5 /var/tmp/lab-oom.log2>/dev/null | sed 's/^/    /'
    return
  fi

  echo "  当前内存："
  free -h | sed 's/^/    /'

  set_state oom
  echo
  echo "请按《Ubuntu故障排查实战.md》第 3.6 节排查。"
  echo "  重点命令：free -h"
  echo "  ps aux --sort=-%mem | head -15"
  echo "  ps -o pid,rss,etime,cmd -p $pid     # 观察 RSS 约 $((mem * 1024)) KB"
  echo "  sudo dmesg -T | grep -iE 'oom|killed process'   # 内存不够时会看到 OOM 记录"
  echo "清理：sudo bash $0 restore"
}

# 场景 4：端口被占用
inject_port() {
  title "注入故障：端口被占用"
  local port="${1:-4002}"
  echo "用一个临时进程占住 $port 端口，模拟僵尸进程"

  if ss -tln | grep -q ":$port "; then
    warn "端口 $port 已被占用，可能本身就是故障状态"
  fi

  nohup python3 -c "
import socket, time
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('0.0.0.0', $port))
s.listen(5)
time.sleep(3600)
" > /var/tmp/lab-port.log 2>&1 &
  local pid=$!
  sleep 2
  printf '%s' "$pid" | sudo tee "$STATE_FILE.port" >/dev/null 2>&1

  # 必须确认端口真的被占住了，否则场景不成立
  if ss -tlnp 2>/dev/null | grep -q ":$port "; then
    ok "端口 $port 已被 PID $pid 占用"
  else
    warn "占用失败（可能没有 python3），本场景无法继续"
    echo "  日志："
    sudo tail -3 /var/tmp/lab-port.log 2>/dev/null | sed 's/^/    /'
    kill "$pid" 2>/dev/null || true
    sudo rm -f /var/tmp/lab-port.log "$STATE_FILE.port"
    return
  fi

  # 停掉 api-server2 并尝试重启，让它撞上端口冲突
  sudo systemctl stop api-server2 2>/dev/null || true
  sudo systemctl start api-server2 2>/dev/null || true
  sleep 3

  echo
  echo "api-server2 已尝试启动，观察它的状态："
  systemctl --no-pager --lines=0 status api-server2 2>/dev/null | head -4 | sed 's/^/  /'

  set_state port
  echo
  echo "请按《Ubuntu故障排查实战.md》第 3.8 节排查。"
  echo "  重点命令：journalctl -u api-server2 -n 50 --no-pager"
  echo "  sudo ss -tlnp | grep ':$port'"
  echo "  sudo lsof -i :$port"
  echo "清理：sudo bash $0 restore"
}

# 场景 5：Nginx 配置语法错误
inject_badconf() {
  do_backup
  title "注入故障：Nginx 配置语法错误"
  echo "在站点配置的 server 块里插入一个错误指令"

  if sudo grep -q 'lab_broken_directive' "$NGINX_SITE" 2>/dev/null; then
    warn "已存在注入标记，先还原：sudo bash $0 restore"
    return
  fi

  sudo sed -i '/server_name/a\    this_directive_does_not_exist_lab_broken;' "$NGINX_SITE"
  ok "已插入错误指令"

  echo
  echo "此时执行 systemctl reload nginx 会失败："
  echo "  sudo nginx -t                    # 看具体错在第几行"
  echo "  sudo tail -20 /var/log/nginx/error.log"
  echo
  echo "现在访问 http://localhost 也会 502（因为 Nginx 仍在跑旧配置或已挂）。"
  echo "请按《Ubuntu故障排查实战.md》第 3.3 节排查。"
  echo "清理：sudo bash $0 restore"
  set_state badconf
}

# 场景 6：权限被改（403）
inject_perm() {
  title "注入故障：文件权限丢失 → 403"
  local target="$PROJECT_DIR/frontend/index.html"

  if [ ! -f "$target" ]; then
    warn "找不到 $target，请确认项目已部署"
    return
  fi

  do_backup

  # 记录原始权限，还原时精确恢复（而不是粗暴改成 644）
  local orig_mode
  orig_mode=$(stat -c '%a' "$target")
  printf '%s' "$orig_mode" | sudo tee "$STATE_FILE.perm" >/dev/null 2>&1
  echo "原权限记录为 $orig_mode，还原时会精确恢复"

  echo
  echo "把 index.html 权限改为 600（属主不可读），模拟权限问题"
  sudo chmod 600 "$target"
  ls -l "$target" | sed 's/^/  /'
  sudo nginx -t >/dev/null 2>&1 && sudo systemctl reload nginx

  set_state perm
  echo
  echo "现在用非属主身份访问会得到 403 Forbidden。"
  echo "请按《Ubuntu故障排查实战.md》第 3.9 节排查。"
  echo "  重点命令：ps -o user,group,cmd -C nginx"
  echo "  namei -l $target"
  echo "  sudo -u www-data cat $target > /dev/null && echo 可读"
  echo "清理：sudo bash $0 restore"
}

# 场景 7：systemd 重启循环
inject_restart_loop() {
  do_backup
  title "注入故障：systemd 重启循环"
  echo "把 api-server1 的 ExecStart 指向一个不存在的文件"
  echo "配合 Restart=always，会造成无限重启"

  sudo sed -i 's|^ExecStart=.*|ExecStart=/usr/bin/node /nonexistent/path/api-server1.js|' \
    /etc/systemd/system/api-server1.service

  sudo systemctl daemon-reload
  sudo systemctl reset-failed api-server1 2>/dev/null || true
  sudo systemctl restart api-server1

  sleep 3
  echo
  echo "当前重启次数："
  systemctl show api-server1 -p NRestarts | sed 's/^/  /'
  systemctl status api-server1 --no-pager 2>/dev/null | head -5 | sed 's/^/  /'

  set_state restart-loop
  echo
  echo "请按《Ubuntu故障排查实战.md》第 3.4 节排查。"
  echo "关键：journalctl -u api-server1 -n 50 会显示 code=203/EXEC"
  echo "清理：sudo bash $0 restore"
}

# 场景 8：后端响应慢 → 504
inject_timeout() {
  title "注入故障：后端响应慢 → 504"
  echo "启动一个延迟 120 秒的假后端，替换 api-server2"

  sudo systemctl stop api-server2 2>/dev/null || true
  sleep 1

  cat > "$PROJECT_DIR/backend/slow-server.js" <<'SLOWJS'
const http = require('http');
http.createServer((req, res) => {
  console.log(`[慢服务器] 收到 ${req.url}，延迟 120 秒后响应`);
  setTimeout(() => {
    res.writeHead(200, {'Content-Type': 'application/json'});
    res.end(JSON.stringify({code:200, server:'慢服务器', data:'终于返回了'}));
  }, 120000);
}).listen(4002, () => console.log('[慢服务器] 已启动，监听 4002（每个请求延迟 120 秒）'));
SLOWJS

  nohup node "$PROJECT_DIR/backend/slow-server.js" \
    > "$LOG_DIR/slow-server.log" 2>&1 &
  local pid=$!
  echo "$pid" | sudo tee "$STATE_FILE.slow" >/dev/null 2>&1
  sleep 2

  ok "慢速后端已启动，PID $pid"
  echo "  该后端每个请求延迟 120 秒；Nginx 默认 proxy_read_timeout 为 60 秒"
  echo "  所以 50% 的请求会在等60 秒后返回 504"

  set_state timeout
  echo
  echo "请按《Ubuntu故障排查实战.md》第 3.2 节排查。"
  echo "  重点命令：sudo tail -50 /var/log/nginx/error.log | grep -i timeout"
  echo "  curl -s -o /dev/null -w 'TTFB:%{time_starttransfer}s\\n' http://127.0.0.1:4002/api/user"
  echo "清理：sudo bash $0 restore"
}

# ---------------------------------------------------------------
# 还原
# ---------------------------------------------------------------
cmd_restore() {
  need_root restore
  title "还原全部注入的故障"
  local state
  state=$(get_state)

  # 1. 清理占位进程
  if [ -f "$STATE_FILE.oom" ]; then
    local p; p=$(cat "$STATE_FILE.oom")
    kill "$p" 2>/dev/null && info "已停止内存占用进程 $p"
    rm -f "$STATE_FILE.oom"
  fi
  if [ -f "$STATE_FILE.slow" ]; then
    local p; p=$(cat "$STATE_FILE.slow")
    kill "$p" 2>/dev/null && info "已停止慢速后端 $p"
    rm -f "$STATE_FILE.slow"
  fi
  if [ -f "$STATE_FILE.port" ]; then
    local p; p=$(cat "$STATE_FILE.port")
    kill "$p" 2>/dev/null && info "已停止端口占用进程 $p"
    rm -f "$STATE_FILE.port"
  fi

  # 2. 清理磁盘填充文件
  if [ -f "$STATE_FILE.disk" ]; then
    local f; f=$(cat "$STATE_FILE.disk")
    [ -f "$f" ] && { rm -f "$f"; info "已删除磁盘填充文件 $f"; }
    rm -f "$STATE_FILE.disk"
  fi
  # 兜底：清理所有可能的 filler 文件
  sudo rm -f /var/tmp/lab-filler-* 2>/dev/null || true

  # 3. 还原 Nginx 配置
  if [ -f "$BACKUP_DIR/nginx-app.conf.bak" ]; then
    cp -a "$BACKUP_DIR/nginx-app.conf.bak" "$NGINX_SITE"
    info "已还原站点配置"
  fi
  if [ -f "$BACKUP_DIR/nginx.conf.bak" ]; then
    cp -a "$BACKUP_DIR/nginx.conf.bak" "$NGINX_CONF"
    info "已还原 nginx.conf"
  fi
  sudo rm -f "$NGINX_CONF.lab.bak"

  # 4. 还原 systemd unit
  if [ -f "$BACKUP_DIR/api-server1.service.bak" ]; then
    cp -a "$BACKUP_DIR/api-server1.service.bak" /etc/systemd/system/api-server1.service
    info "已还原 api-server1.service"
  fi
  if [ -f "$BACKUP_DIR/api-server2.service.bak" ]; then
    cp -a "$BACKUP_DIR/api-server2.service.bak" /etc/systemd/system/api-server2.service
    info "已还原 api-server2.service"
  fi
  sudo systemctl daemon-reload
  sudo systemctl reset-failed api-server1 api-server2 2>/dev/null || true

  # 5. 还原文件权限（精确恢复注入前记录的权限）
  if [ -f "$STATE_FILE.perm" ]; then
    local pmode; pmode=$(cat "$STATE_FILE.perm")
    if [ -f "$PROJECT_DIR/frontend/index.html" ]; then
      sudo chmod "$pmode" "$PROJECT_DIR/frontend/index.html" \
        && info "已还原 index.html 权限为 $pmode"
    fi
    rm -f "$STATE_FILE.perm"
  elif [ -f "$PROJECT_DIR/frontend/index.html" ]; then
    sudo chmod 644 "$PROJECT_DIR/frontend/index.html" 2>/dev/null \
      && info "已还原 index.html 权限为 644"
  fi

  # 6. 清理临时文件
  rm -f "$PROJECT_DIR/backend/slow-server.js"
  sudo rm -f /var/tmp/lab-oom.log /var/tmp/lab-port.log
  info "已清理实验临时文件"

  # 7. 重启服务
  title "重启服务"
  sudo nginx -t 2>/dev/null && sudo systemctl reload nginx 2>/dev/null || sudo systemctl restart nginx
  sudo systemctl restart api-server1 api-server2 2>/dev/null
  sleep 2

  systemctl --no-pager --lines=0 status nginx 2>/dev/null | head -3 | sed 's/^/  /'
  systemctl --no-pager --lines=0 status api-server1 2>/dev/null | head -3 | sed 's/^/  /'
  systemctl --no-pager --lines=0 status api-server2 2>/dev/null | head -3 | sed 's/^/  /'

  rm -f "$STATE_FILE"
  ok "还原完成（当前状态：none）"
}

# ---------------------------------------------------------------
# 状态
# ---------------------------------------------------------------
cmd_status() {
  title "当前注入状态"
  local state; state=$(get_state)
  if [ "$state" = "none" ]; then
    ok "环境正常，未注入任何故障"
  else
    warn "已注入故障：$state"
    echo "  排查完记得执行：sudo bash $0 restore"
  fi

  title "进程与端口"
  ss -tlnp 2>/dev/null | grep -E ':80|:4001|:4002' | sed 's/^/  /' || echo "  相关端口未监听"

  title "服务状态"
  systemctl --no-pager --lines=0 status nginx api-server1 api-server2 2>/dev/null | \
    grep -E '●|Active:' | head -10 | sed 's/^/  /'

  title "资源"
  free -h | sed 's/^/  /'
  df -h / | tail -1 | sed 's/^/  /'
}

# ---------------------------------------------------------------
# 参考答案
# ---------------------------------------------------------------
cmd_answer() {
  local scene="${1:-}"
  [ -n "$scene" ] || { die "请指定场景：bash $0 answer 502"; }

  case "$scene" in
    502)
      cat <<'EOF'
【答案】502 Bad Gateway

定位步骤：
1. curl -s http://127.0.0.1:4001/api/user   → 通（后端A 正常）
2. curl -s http://127.0.0.1:4002/api/user   → 通（后端B 正常）
3. curl -s http://127.0.0.1/api/user        → 502
   → 问题在 L2/L3：Nginx 转发层

4. sudo tail -50 /var/log/nginx/error.log | grep upstream
   → connect() failed (111: Connection refused) while connecting to upstream,
     upstream: "http://127.0.0.1:4999/..."
   → 直接告诉你 upstream 指向的端口连不上

5. sudo grep -A5 upstream /etc/nginx/nginx.conf
   → 发现 4002 被写成了 4999

根因：Nginx upstream 配置端口写错。

修复：
  sudo sed -i 's/127.0.0.1:4999/127.0.0.1:4002/' /etc/nginx/nginx.conf
  sudo nginx -t && sudo systemctl reload nginx

关键命令：
  sudo tail -100 /var/log/nginx/error.log | grep -i 'upstream\|connect()'
EOF
      ;;
    disk)
      cat <<'EOF'
【答案】磁盘写满

定位步骤：
1. df -h                  → 哪个分区满了
2. df -i                  → inode 是否也耗尽
3. sudo du -h --max-depth=1 / 2>/dev/null | sort -rh | head -10  → 定位大目录
4. sudo du -h --max-depth=1 /var 2>/dev/null | sort -rh | head
5. sudo find / -xdev -type f -size +1G 2>/dev/null

本场景的注入物：/var/tmp/lab-filler-*.dat

清理：
  sudo rm -f /var/tmp/lab-filler-*.dat
  df -h /    # 确认释放

真实场景常见元凶与清理顺序：
  journalctl --disk-usage               → journal 日志
  sudo journalctl --vacuum-size=200M
  sudo du -sh /var/log/nginx           → nginx 日志
  sudo apt clean                        → apt 缓存
  sudo lsof -nP | grep '(deleted)'     → 已删除但被占着的文件

预防：
  /etc/systemd/journald.conf → SystemMaxUse=500M
  /etc/logrotate.d/nginx    → 确认 timer 在跑
  crontab -e                → 磁盘水位告警
EOF
      ;;
    oom)
      cat <<'EOF'
【答案】内存不足 / OOM

定位步骤：
1. sudo dmesg -T | grep -iE 'out of memory|oom-killer|killed process'
   → 确认是否被 OOM Killer 杀过
   → 关键输出："Memory cgroup out of memory: Killed process XXXX (node)"

2. free -h
   → 看 available，不是 free！buff/cache 是可回收的

3. ps aux --sort=-%mem | head -15
   → RSS 列是实际物理内存（单位 KB）

4. swapon --show
   → 没 swap 时 OOM 会来得非常突然

5. 排查内存泄漏：
   watch -n 5 'ps -o pid,rss,etime,cmd -p $(pgrep -f api-server1 | head -1)'
   → RSS 单调上升不降 = 泄漏

应急处置：
  sudo kill <PID>                                    # 杀掉元凶
  sudo systemctl edit api-server1                    # 加内存上限
    [Service]
    MemoryMax=1500M
  sudo fallocate -l 4G /swapfile && sudo chmod 600 /swapfile
  sudo mkswap /swapfile && sudo swapon /swapfile
  echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab

Node 层限制堆大小（让它主动报错而不是被系统 kill）：
  ExecStart=/usr/bin/node --max-old-space-size=1024 api-server1.js
EOF
      ;;
    port)
      cat <<'EOF'
【答案】端口被占用

定位步骤：
1. systemctl status api-server2 --no-pager
   → Main process exited, code=exited, status=1
   → Active: activating (auto-restart)  ← 在无限重启

2. journalctl -u api-server2 -n 50 --no-pager
   → Error: listen EADDRINUSE: address already in use :::4002

3. sudo ss -tlnp | grep ':4002'
   → 显示 python3 进程占着 4002

4. sudo lsof -i :4002
   → 同样的信息

处置：
  sudo kill <占用进程的PID>
  sleep 2
  sudo lsof -i :4002 || echo "端口已释放"
  sudo systemctl restart api-server2

关键区别：
  - EADDRINUSE → 端口被占，找 lsof/ss 找出谁占的
  - EADDRNOTAVAIL → 绑定到不存在的 IP
  - 只看 TIME_WAIT 不代表真占用，等 60 秒自动释放

预防：
  ss -tlnp | grep -q ':4002' && echo "警告：4002 已被占用"
  systemd 里用 Type=forking + PIDFile 或 .socket 单元精确管理
EOF
      ;;
    badconf)
      cat <<'EOF'
【答案】Nginx 配置语法错误

定位步骤：
1. sudo nginx -t
   → nginx: [emerg] unknown directive "this_directive_does_not_exist_lab_broken"
   → nginx: configuration file /etc/nginx/nginx.conf test failed
   → 直接告诉你行号

2. sudo tail -20 /var/log/nginx/error.log
   → 记录了 reload 失败的原因

3. 查看错误行附近的配置
   sudo sed -n '10,30p' /etc/nginx/sites-available/nginx-app

处置：
  A. 有备份：
     sudo cp /etc/nginx/sites-available/nginx-app.bak \
             /etc/nginx/sites-available/nginx-app
     sudo nginx -t && sudo systemctl reload nginx
  B. 手动改：sudo nano /etc/nginx/sites-available/nginx-app
     删掉错误行后 sudo nginx -t && sudo systemctl reload nginx
  C. 本实验：sudo bash deploy/lab-troubleshoot.sh restore

黄金法则：
  改完配置 ALWAYS 先 nginx -t，通过了再 reload。
  reload 不中断连接，restart 会。
EOF
      ;;
    perm)
      cat <<'EOF'
【答案】403 Forbidden / 权限问题

定位步骤：
1. ps -o user,group,cmd -C nginx
   → nginx 以 www-data 身份运行

2. sudo nginx -T | grep -E 'root|alias'
   → root 指向的绝对路径

3. sudo ls -la /home/<用户名>/nginx-project/frontend/index.html
   → 权限 000，连读都不允许

4. namei -l /home/<用户名>/nginx-project/frontend/index.html
   → 逐级检查路径上每一级目录的 x（执行）权限
   → 常见坑：家目录是 drwx------，www-data 进不去

5. sudo -u www-data cat /path/to/index.html
   → 模拟 nginx 身份实际读一次，最直接的验证

处置：
  sudo chmod 644 /home/<用户名>/nginx-project/frontend/index.html
  sudo chmod 755 /home/<用户名>              # 目录需要 x
  sudo chown -R www-data:www-data /var/www/html

关键区别：
  403 = 有权限但被拒绝（Nginx 还能读到文件但不允许访问，或权限不足）
  404 = 路径不对（root 指错、文件不存在）
EOF
      ;;
    restart-loop)
      cat <<'EOF'
【答案】systemd 无限重启循环

定位步骤：
1. systemctl show api-server1 -p NRestarts
   → NRestarts=47  ← 确认在重启

2. systemctl status api-server1 --no-pager
   → Main process exited, code=203/EXEC, status=203/EXEC
   → status=9/KILL 则是被 OOM 或 kill -9

3. journalctl -u api-server1 -n 100 --no-pager
   → status=203/EXEC, status=1/FAILURE
   → 显示 "Failed at step EXEC spawning /nonexistent/path/api-server1.js"

4. systemctl cat api-server1
   → 核对 User / WorkingDirectory / ExecStart 三项

systemd 退出码对照：
  status=1/FAILURE   → 程序自己抛异常退出，看应用日志
  status=9/KILL      → 被强杀，OOM 或人工 kill，看 dmesg
  code=203/EXEC      → ExecStart 路径不存在或没有执行权限
  code=200/CHDIR     → WorkingDirectory 不存在
  code=206/GROUP     → User 指定的组不存在
  code=217/USER      → User 指定的用户不存在

处置：
  1. 止损：sudo systemctl stop api-server1
  2. 修正 ExecStart 后：sudo systemctl daemon-reload
  3. 启动：sudo systemctl restart api-server1
  4. 验证：systemctl show api-server1 -p NRestarts  不再增长

防护：
  sudo systemctl edit api-server1
  [Service]
  Restart=on-failure
  RestartSec=10
  StartLimitIntervalSec=300
  StartLimitBurst=3
  → 5 分钟内重启超过 3 次就放弃，防止日志被刷爆

调试技巧：
  sudo systemctl reset-failed api-server1
  cd /path/to/backend && node api-server1.js   # 绕过 systemd 直接前台跑
EOF
      ;;
    timeout)
      cat <<'EOF'
【答案】504 Gateway Timeout

定位步骤：
1. sudo tail -50 /var/log/nginx/error.log | grep -i timeout
   → upstream timed out while reading response header from upstream
   → 说明是"连上了但太慢"，不是"连不上"

2. curl -s -o /dev/null -w 'TTFB:%{time_starttransfer}s Total:%{time_total}s\n' \
     http://127.0.0.1:4002/api/user
   → 对比 4001 和 4002，发现哪个慢

3. ss -tlnp | grep ':4002'
   → 会发现进程是 slow-server.js 而不是 api-server2.js

4. ps aux | grep slow-server
   → 找到延迟注入的进程

5. top -H -p <PID>   # -H 显示线程
   → 看是哪个线程卡住

处置：
  应急：sudo systemctl stop api-server2（摘掉故障节点）
  调超时（治标）：
    proxy_read_timeout 120s;
  根治：找慢的根本原因（DB 慢查询 / 同步阻塞 IO / CPU 密集计算）

本场景清理：
  sudo bash deploy/lab-troubleshoot.sh restore
EOF
      ;;
    *)
      die "未知场景：$scene。可用场景：502 disk oom port badconf perm restart-loop timeout"
      ;;
  esac
}

# ---------------------------------------------------------------
# 场景列表
# ---------------------------------------------------------------
cmd_list() {
  cat <<'EOF'

  故障注入实验场景
  ==================

  场景         难度  说明                          排查章节
  ----------  ----  ----------------------------  ------------------------
  502          ⭐     upstream 端口写错             手册 3.1
  perm         ⭐     文件权限变000 → 403           手册 3.9
  port         ⭐     端口被占，服务起不来            手册 3.8
  disk         ⭐⭐   磁盘写满                      手册 3.5
  oom          ⭐⭐   内存飙升 / OOM                手册 3.6
  badconf      ⭐⭐   Nginx 配置语法错误            手册 3.3
  timeout      ⭐⭐   后端响应慢 → 504              手册 3.2
  restart-loop ⭐⭐⭐  systemd 无限重启循环          手册 3.4

  用法：
    bash deploy/lab-troubleshoot.sh list
    bash deploy/lab-troubleshoot.sh doctor                 # 环境体检
    sudo bash deploy/lab-troubleshoot.sh inject 502         # 注入故障
    sudo bash deploy/lab-troubleshoot.sh restore           # 还原
    bash deploy/lab-troubleshoot.sh answer 502             # 参考答案

  推荐练习顺序：
    先跑 doctor 确认环境 OK
    → inject 502（练日志阅读和定位）
    → inject port（练进程/端口排查）
    → inject perm（练权限）
    → inject timeout（练耗时分析）
    → inject badconf（练配置排查）
    → inject disk（练磁盘清理）
    → inject oom（练内存分析）
    → inject restart-loop（练 systemd，最难）

  ⚠️ 请在 WSL / 测试机上演练，不要在生产服务器上运行 inject。

EOF
}

# ---------------------------------------------------------------
# 入口
# ---------------------------------------------------------------
case "${1:-}" in
  list|"")
    cmd_list
    ;;
  doctor)
    cmd_doctor
    ;;
  status)
    cmd_status
    ;;
  answer)
    shift; cmd_answer "$@"
    ;;
  inject)
    shift
    case "${1:-}" in
      502)          inject_502 ;;
      disk)         shift 2>/dev/null; inject_disk "$@" ;;
      oom)          shift 2>/dev/null; inject_oom "$@" ;;
      port)         shift 2>/dev/null; inject_port "$@" ;;
      badconf)      inject_badconf ;;
      perm)         inject_perm ;;
      restart-loop) inject_restart_loop ;;
      timeout)      inject_timeout ;;
      *)            cmd_list; die "未知场景：${1:-（空）}" ;;
    esac
    ;;
  restore)
    cmd_restore
    ;;
  *)
    echo "未知命令：$1"
    echo ""
    cmd_list
    exit 1
    ;;
esac