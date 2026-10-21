# Ubuntu 线上故障排查实战手册

> 配套文件：`deploy/lab-troubleshoot.sh`（故障注入实验脚本，可以亲手把服务搞坏再捞回来）
> 前置知识：`Ubuntu运维指令教程.md`（命令大全，本文不重复讲参数含义，只讲**什么时候敲什么**）
> 演练环境：本项目的 Nginx + 两个 Node 后端（4001 / 4002）

---

## 目录

- [第 0 章 排障前的五条铁律](#第-0-章-排障前的五条铁律)
- [第 1 章 六层定位法（核心框架）](#第-1-章-六层定位法核心框架)
- [第 2 章 第一现场信息采集](#第-2-章-第一现场信息采集)
- [第 3 章 场景化排查手册](#第-3-章-场景化排查手册)
  - [3.1 502 Bad Gateway](#31-502-bad-gateway)
  - [3.2 504 Gateway Timeout](#32-504-gateway-timeout)
  - [3.3 连接被拒绝 / 页面打不开](#33-连接被拒绝--页面打不开)
  - [3.4 服务反复自动重启](#34-服务反复自动重启)
  - [3.5 磁盘写满](#35-磁盘写满)
  - [3.6 内存不足 / 被 OOM Kill](#36-内存不足--被-oom-kill)
  - [3.7 CPU 打满 / load 飙高](#37-cpu-打满--load-飙高)
  - [3.8 端口被占用，服务起不来](#38-端口被占用服务起不来)
  - [3.9 403 Forbidden 权限问题](#39-403-forbidden-权限问题)
  - [3.10 磁盘 IO 高、响应变慢](#310-磁盘-io-高响应变慢)
  - [3.11 连接数耗尽 / Too many open files](#311-连接数耗尽--too-many-open-files)
- [第 4 章 日志分析速查](#第-4-章-日志分析速查)
- [第 5 章 三个完整实战案例](#第-5-章-三个完整实战案例)
- [第 6 章 应急处置 vs 根因修复](#第-6-章-应急处置-vs-根因修复)
- [第 7 章 排障记录模板](#第-7-章-排障记录模板)
- [第 8 章 预防性 checklist](#第-8-章-预防性-checklist)

---

## 第 0 章 排障前的五条铁律

新手排障最大的问题不是不会敲命令，而是**乱敲**。以下五条比任何命令都重要。

### 铁律 1：先救火，再定位

服务已经挂了、用户在骂，先恢复再查原因。

```bash
# 判断标准：已经造成业务损失（用户访问不了/下单失败）→ 先恢复
# 优先顺序：
#   1. 流量还有一半能通（Nginx 存活，部分 upstream 挂）→ 先只读排查，不动配置
#   2. 完全不通 → 先回滚到上一个可用版本，再慢慢查
#   3. 只影响某个非核心功能 → 记录现场后修复
```

### 铁律 2：重启会销毁现场

90% 的人第一反应是 `systemctl restart`。**重启前先把现场存下来**：

```bash
# 保存现场（30 秒，养成习惯）
sudo journalctl -u api-server1 --since "30 min ago" --no-pager > /tmp/incident-$(date +%s).log
sudo ss -antp > /tmp/ss-snapshot.txt
ps auxf > /tmp/ps-tree.txt
free -h && df -h > /tmp/resource.txt
dmesg -T | tail -100 > /tmp/dmesg.txt
```

重启之后这些日志可能就永远拿不到了。特别是**内存泄漏、句柄泄漏、死锁**这类问题，重启一次现场就没了。

### 铁律 3：一次只改一个变量

同时改配置 + 换端口 + 重启，然后"好像好了"——你并不知道是哪个起的作用，下次还会复发。

### 铁律 4：生产环境的任何改动，先备份

```bash
# Nginx 配置
sudo cp /etc/nginx/sites-available/nginx-app /etc/nginx/sites-available/nginx-app.bak.$(date +%F-%H%M)

# systemd unit
sudo cp /etc/systemd/system/api-server1.service /etc/systemd/system/api-server1.service.bak

# 改 Nginx 之前 ALWAYS 先做语法检查
sudo nginx -t && sudo systemctl reload nginx
```

> `reload` 不中断现有连接，`restart` 会。生产环境永远优先 `reload`。

### 铁律 5：所有操作带时间戳记录

```bash
# 一个好用的现场记录命令
ts() { echo "[$(date '+%F %T')] $*" | tee -a /tmp/incident.log; }
ts "开始排查 502 问题"
ts "查看 nginx error.log 最后 50 行"
```

事后复盘时，你不用回忆当时干了啥。

---

## 第 1 章 六层定位法（核心框架）

线上故障千变万化，但**排查方向永远是固定的**。记住这条链路，从上往下逐层排除，不要跳层。

```
                    ┌─────────────────────────────────────┐
     L1  外网可达   │ DNS 解析 → 路由 → 安全组/防火墙       │  用户能到你这台机器吗
                    └───────────────┬─────────────────────┘
                                    ↓ 能到
                    ┌─────────────────────────────────────┐
     L2  接入层     │ Nginx / LB / 网关进程活着吗？        │  谁在门口接客
                    └───────────────┬─────────────────────┘
                                    ↓ 活着
                    ┌─────────────────────────────────────┐
     L3  代理转发   │ Nginx 能不能连上 upstream？           │  门口的人往里走通吗
                    └───────────────┬─────────────────────┘
                                    ↓ 通
                    ┌─────────────────────────────────────┐
     L4  应用进程   │ 应用进程在吗？端口监听吗？            │  里面有人上班吗
                    └───────────────┬─────────────────────┘
                                    ↓ 在
                    ┌─────────────────────────────────────┐
     L5  应用逻辑   │ 本机直连 curl 通了吗？返回对吗？       │  他能不能干活
                    └───────────────┬─────────────────────┘
                                    ↓ 通
                    ┌─────────────────────────────────────┐
     L6  资源/依赖 │ CPU/内存/磁盘/DB/Redis/第三方接口       │  原料够吗、依赖通吗
                    └─────────────────────────────────────┘
```

**口诀：从外往里，从上往下，一层一层排除。**

新手最常见的错误是**跳层**——直接跳到 L6 去查内存，或者直接改 Nginx 配置。其实 L3 一条 `tail error.log` 就能定位 80% 的问题。

### 各层的验证命令速查

| 层 | 一条命令验证 | 通过标准 |
|---|---|---|
| L1 外网 | `dig +short your-domain.com` / `curl -I http://<公网IP>` | 解析到你期望的 IP，HTTP 有响应 |
| L1 防火墙 | `sudo ufw status` / `sudo iptables -L -n` | 目标端口在白名单里 |
| L2 接入层 | `systemctl status nginx` | Active: active (running) |
| L2 接入层 | `sudo ss -tlnp \| grep ':80'` | 有 nginx 在 LISTEN |
| L3 代理转发 | `sudo tail -50 /var/log/nginx/error.log` | 没有 `connect() failed` |
| L3 代理转发 | `sudo nginx -t` | syntax is ok / test is successful |
| L4 应用进程 | `systemctl status api-server1` | Active: active (running) |
| L4 应用进程 | `ss -tlnp \| grep 4001` | 有 node 在 LISTEN |
| L5 应用逻辑 | `curl -s http://127.0.0.1:4001/api/user` | 返回 JSON，`"server":"服务器A"` |
| L6 资源 | `free -h` / `df -h` / `uptime` | available 内存充足，磁盘 <85%，load < 核数 |
| L6 依赖 | `nc -zv 127.0.0.1 6379` / `curl -s db-health-url` | 依赖端口通 |

**关键技巧：对比测试定位故障层**

```bash
# 同一个请求，三种打法的结果对比，就能精确定位是哪一层坏了

# A. 直连应用（绕过 Nginx）—— 测 L4/L5
curl -s http://127.0.0.1:4001/api/user

# B. 走 Nginx（测 L2/L3）
curl -s http://127.0.0.1/api/user

# C. 走域名（测 L1）
curl -s http://your-domain.com/api/user
```

| A | B | C | 结论 |
|---|---|---|---|
| 通 | 通 | 不通 | L1 问题：DNS / 防火墙 / 安全组 |
| 通 | 不通 | 不通 | L2/L3 问题：Nginx 配置或转发 |
| 不通 | 不通 | 不通 | L4/L5 问题：应用挂了 |

**一张表走天下**。以后遇到任何"访问不了"，先跑这三条 curl。

---

## 第 2 章 第一现场信息采集

故障发生时，在动手改任何东西之前，先跑一遍这段，把**所有基础信息**存下来。

```bash
#!/bin/bash
# 一键现场采集脚本，输出建议保存
echo "===== 1. 系统与时间 ====="
date; uptime; hostname; uname -a

echo; echo "===== 2. 资源（最常见的根因）====="
free -h
df -h
df -i                        # inode 是否耗尽（文件多但空间没满的元凶）
echo "--- load / CPU ---"
nproc
top -bn1 | head -5

echo; echo "===== 3. 内存占用 TOP10 ====="
ps aux --sort=-%mem | head -11

echo; echo "===== 4. 服务状态（找出所有 failed 的）====="
systemctl --failed --no-pager
systemctl status nginx --no-pager | head -15
systemctl status api-server1 api-server2 --no-pager | head -30

echo; echo "===== 5. 端口监听 ====="
sudo ss -tlnp

echo; echo "===== 6. 连接状态统计 ====="
ss -s
ss -ant | awk '{print $1}' | sort | uniq -c | sort -rn

echo; echo "===== 7. Nginx 错误日志（最后 50 行）====="
sudo tail -50 /var/log/nginx/error.log

echo; echo "===== 8. Nginx 配置检查 ====="
sudo nginx -t

echo; echo "===== 9. 应用日志 ====="
journalctl -u api-server1 -n 50 --no-pager
journalctl -u api-server2 -n 50 --no-pager

echo; echo "===== 10. 内核层（OOM / 磁盘 / 网络错误）====="
sudo dmesg -T | grep -iE 'oom|killed process|i/o error|segfault|out of memory' | tail -20

echo; echo "===== 11. 磁盘占用 TOP 目录 ====="
sudo du -h --max-depth=1 /var 2>/dev/null | sort -rh | head -10
```

保存为 `~/collect.sh`，`bash ~/collect.sh | tee ~/incident-report.txt`。

> 建议把这个脚本放到每台服务器上，平时不用，出事一键跑。

---

## 第 3 章 场景化排查手册

### 3.1 502 Bad Gateway

**含义**：Nginx 收到了请求，但把请求转给后端时**连接失败**了。

**根因分布（本项目场景）**：
- upstream 端口写错 / 后端没起（占 60%）
- 后端进程崩了（25%）
- 后端只监听了 `127.0.0.1` 但 Nginx 在另一个网络命名空间（少见）
- 后端起来了但启动中，Nginx 还没等到就断了

#### 排查步骤

```bash
# 步骤 1（最高优先级）：看 Nginx 错误日志，它会直接告诉你失败原因
sudo tail -100 /var/log/nginx/error.log | grep -i 'upstream\|connect()'

# 典型输出 A —— 连接被拒绝：后端根本没在监听
# connect() failed (111: Connection refused) while connecting to upstream,
# client: 1.2.3.4, server: your-domain.com, request: "GET /api/user HTTP/1.1",
# upstream: "http://127.0.0.1:4002/api/user"

# 典型输出 B —— 超时：后端太慢或网络不通
# upstream timed out (110: Connection timed out) while connecting to upstream

# 典型输出 C —— 无可用后端：upstream 块里的机器全挂了
# no live upstreams while connecting to upstream
```

```bash
# 步骤 2：确认 Nginx 配置里 upstream 端口是多少
sudo grep -A5 'upstream api_backend' /etc/nginx/nginx.conf /etc/nginx/sites-enabled/* 2>/dev/null
# 注意：upstream 定义在 http{} 块（通常在 nginx.conf 里），
#      location/proxy_pass 定义在 server 块（在 sites-enabled 里）——两个地方都要看

# 步骤 3：实际监听情况对不对得上
ss -tlnp | grep -E ':4001|:4002'
# 配置写 4002，实际只有 4001 在监听 → 根因确认

# 步骤 4：本机直连验证（绕过 Nginx）
curl -sv http://127.0.0.1:4002/api/user 2>&1 | tail -5
# Connection refused → 后端没起
# 200 + JSON → 后端正常，问题在 Nginx 配置或防火墙

# 步骤 5：后端进程状态
systemctl status api-server2 --no-pager
journalctl -u api-server2 -n 50 --no-pager

# 步骤 6：确认配置改过没有
sudo nginx -t
systemctl is-active nginx
```

#### 本项目最可能的三个坑

```bash
# 坑 1：配置文件放错地方
# upstream 定义了但没被 include 进来
ls -la /etc/nginx/sites-enabled/
grep -c 'upstream' /etc/nginx/nginx.conf

# 坑 2：软链接没建
# /etc/nginx/sites-enabled/nginx-app 应该是指向 sites-available 的符号链接
ls -l /etc/nginx/sites-enabled/
# 显示 -rw-r--r-- 而不是 lrwxrwxrwx → 说明是复制的普通文件，改了原文件不会生效

# 坑 3：改了配置没 reload
# 改完必须：sudo nginx -t && sudo systemctl reload nginx
```

---

### 3.2 504 Gateway Timeout

**含义**：Nginx 连上后端了，但后端**响应太慢**，Nginx 等超时了。

**根因分布**：
- 后端在处理慢请求 / 死循环 / 阻塞 IO（50%）
- 数据库慢查询（25%）
- 后端线程池/连接池打满（15%）
- Nginx 的 `proxy_read_timeout` 太短（10%）

#### 排查步骤

```bash
# 步骤 1：确认是"慢"而不是"连不上"
sudo tail -50 /var/log/nginx/error.log | grep -i 'timeout'
# upstream timed out while reading response header from upstream  ← 后端慢
# connect() timed out  ← 网络/端口层问题，归 502 类

# 步骤 2：手动测响应耗时
curl -s -o /dev/null -w 'HTTP:%{http_code} DNS:%{time_namelookup}s 连接:%{time_connect}s 首字节:%{time_starttransfer}s 总计:%{time_total}s\n' \
  http://127.0.0.1:4001/api/user
# 首字节 > 1s 就说明后端确实慢

# 步骤 3：对比两个后端，找出慢的那个
for port in 4001 4002; do
  echo "--- $port ---"
  curl -s -o /dev/null -w "总计:%{time_total}s\n" http://127.0.0.1:$port/api/user
done

# 步骤 4：后端进程在忙什么
top -H -p $(pgrep -f api-server1 | head -1)
# -H 显示线程级，看是不是某个线程卡住
node --inspect  # 或者用 clinic / 0x 做 CPU profiling

# 步骤 5：默认超时值是多少
sudo nginx -T | grep -E 'proxy_(read|connect|send)_timeout'
# 默认 proxy_read_timeout 60s；超过这个时间后端还没返回就 504

# 步骤 6：系统层面是否资源耗尽
iostat -x 1 3      # %util 接近 100 → 磁盘是瓶颈
vmstat 1 3        # si/so 持续非 0 → 正在换页，内存不足
```

#### 应急与根治

```bash
# 应急：临时调大超时（治标，不治本）
# 在 location /api/ 块里加：
#   proxy_connect_timeout 5s;
#   proxy_read_timeout 120s;
sudo nano /etc/nginx/sites-available/nginx-app
sudo nginx -t && sudo systemctl reload nginx

# 根治：找慢的根本原因（数据库慢查询 / 同步阻塞 IO / CPU 密集计算）
```

---

### 3.3 连接被拒绝 / 页面打不开

**场景**：浏览器显示 `ERR_CONNECTION_REFUSED` 或 `无法访问此网站`。

#### 排查步骤（严格按顺序）

```bash
# 步骤 1：Nginx 在跑吗
systemctl status nginx

# 步骤 2：80 端口有人监听吗
sudo ss -tlnp | grep ':80'
# 空 → Nginx 没起来，或者监听的不是 80
# 看到 LISTEN 0.0.0.0:80 才对外网开放
# 如果是 127.0.0.1:80 → 只有本机能访问，外网连不上

# 步骤 3：文件描述符够吗（high connection load 时 Nginx 会拒绝）
ulimit -n
sudo nginx -T | grep -i worker_rlimit
# worker_connections 1024 不够会报 "too many open files" 或 "worker_connections are not enough"

# 步骤 4：防火墙
sudo ufw status verbose
sudo iptables -L -n | grep -E 'dport (80|443)'
# 云服务器还要看：安全组 / 网络 ACL（这一层 ufw 看不到！）

# 步骤 5：Nginx 监听的是哪个 IP
sudo ss -tlnp | grep nginx
# 127.0.0.1:80 = 只有本机
# 0.0.0.0:80   = 所有网卡 → 外网可访问
# 具体IP:80   = 只有这个网卡

# 步骤 6：本机自测（排除外部网络因素）
curl -I http://127.0.0.1
# 通 → 问题在外部（DNS/安全组/防火墙/负载均衡）
# 不通 → 问题在本机

# 步骤 7：从外部视角测
curl -I http://$(hostname -I | awk '{print $1}')
# 模拟"从本机走网卡访问"，和访问 127.0.0.1 的区别就是绑定了网卡
```

> **WSL 特别注意**：Windows 访问 WSL 服务走的是 WSL 虚拟网卡 IP，不是 127.0.0.1。
> `hostname -I` 查 IP。如果 Windows 侧不通，大概率是 **Windows 防火墙**挡了 WSL 的入站。

---

### 3.4 服务反复自动重启

**现象**：`systemctl status` 显示服务一会儿 active 一会儿 failed，或者日志刷屏 `Started xxx` / `Stopped xxx`。

**这是 systemd 最常见的问题**，`Restart=always` + 启动就崩 = 无限重启循环。

#### 排查步骤

```bash
# 步骤 1：看重启次数
systemctl show api-server1 -p NRestarts
# NRestarts = 47 → 确认在反复重启

# 步骤 2：看它为什么崩（关键）
journalctl -u api-server1 -n 100 --no-pager
journalctl -u api-server1 --since "10 min ago" --no-pager

# 步骤 3：看退出的错误码（新手最容易忽略但信息量最大的一点）
systemctl status api-server1 --no-pager
```

**systemd 退出码对照表**（`Main process exited, code=xxx`）：

| 退出码 | 状态 | 含义 | 排查方向 |
|---|---|---|---|
| `code=exited, status=1` | 一般错误 | 程序自己抛异常退出 | 看应用日志最后几行，通常有 stack trace |
| `code=killed, status=9/KILL` | 被强杀 | **OOM** 或被人 `kill -9` | `dmesg -T \| grep -i oom` |
| `code=203/EXEC` | 启动失败 | `ExecStart` 路径不存在或没执行权限 | `ls -l` 检查路径，`command -v node` |
| `code=200/CHDIR` | 启动失败 | `WorkingDirectory` 不存在 | `ls -ld` 检查目录 |
| `code=206/GROUP` | 启动失败 | `User=` 指定的用户组不存在 | `getent group 用户名` |
| `code=217/USER` | 启动失败 | `User=` 指定的用户不存在 | `id 用户名` |
| `code=203/EXEC` + 权限 | — | 文件没有执行位 | `chmod +x` |

```bash
# 步骤 4：看 unit 文件本身
systemctl cat api-server1
# 重点核对：User / WorkingDirectory / ExecStart 三项

# 步骤 5：验证路径确实存在
ls -l "$(systemctl show api-server1 -p ExecStart --value | awk '{print $2}')"
```

#### 立刻止损

```bash
# 停止重启风暴（先止血，再分析）
sudo systemctl stop api-server1
# 或临时禁用自动重启
sudo systemctl edit api-server1
# 加：
#   [Service]
#   Restart=no
# 然后：sudo systemctl daemon-reload && sudo systemctl restart api-server1
```

#### 用 systemd 自带的调试模式直接前台跑

```bash
# 最有效的调试方式：绕过 systemd 直接跑，看到完整的 stderr
cd ~/nginx-project/backend && node api-server1.js

# 或者只清空 Restart 策略后手动跑
sudo systemctl reset-failed api-server1
```

---

### 3.5 磁盘写满

**危害**：日志写不进去、服务无法启动、数据库崩溃。

#### 排查步骤

```bash
# 步骤 1：哪个分区满了
df -h
# Filesystem      Size  Used Avail Use% Mounted on
# /dev/vda1        20G   19G  1.0G  95% /      ← 这里

# 步骤 2：inode 也要看（文件太多但空间没满是这个）
df -i
# 小文件场景（日志碎片、缓存）经常是 inode 先耗尽

# 步骤 3：定位大目录（神器命令）
sudo du -h --max-depth=1 / 2>/dev/null | sort -rh | head -10
sudo du -h --max-depth=1 /var 2>/dev/null | sort -rh | head -10
sudo du -h --max-depth=1 /var/log 2>/dev/null | sort -rh | head

# 步骤 4：找出具体的大文件
sudo find / -xdev -type f -size +500M 2>/dev/null -exec ls -lh {} \;
```

#### 常见元凶与清理（按安全性排序）

```bash
# 元凶 1：journal 日志（最常见的隐形杀手）
journalctl --disk-usage                                  # 先看占了多少
sudo journalctl --vacuum-size=200M                      # 清到 200M
# 永久方案：/etc/systemd/journald.conf 里设 SystemMaxUse=200M

# 元凶 2：Nginx 日志（没配 logrotate 的话会无限增长）
ls -lh /var/log/nginx/
sudo du -sh /var/log/nginx
# 检查 logrotate 配置
sudo cat /etc/logrotate.d/nginx
# 强制轮转测试
sudo logrotate -d /etc/logrotate.d/nginx     # -d 是 dry-run，先看会做什么
sudo logrotate -f /etc/logrotate.d/nginx     # -f 强制执行

# 元凶 3：apt 缓存
sudo apt clean                    # 清 /var/cache/apt/archives
sudo du -sh /var/cache/apt

# 元凶 4：应用自己写的日志（本项目）
du -sh ~/nginx-project/logs/
# 手动清理归档的旧日志（保留最近 7 天）
find ~/nginx-project/logs -name '*.log.*' -mtime +7 -delete

# 元凶 5：临时文件 / 已删除但未释放的文件（很隐蔽）
sudo lsof -nP | grep '(deleted)'
# 进程持有已删除的 fd，磁盘空间不会释放
# 找到进程后重启它：sudo systemctl restart <服务名>

# 元凶 6：Docker（本机没装就跳过）
docker system df
docker system prune -a          # 注意：会删掉所有未被使用的镜像和容器
```

> ⚠️ **清理红线**：不要对 `/` 执行 `rm -rf`，不要动 `/var/lib/` 下的数据库目录。
> 删除前先 `du -sh` 确认，`find ... -delete` 之前先用同样的条件 `-print` 看一遍。

---

### 3.6 内存不足 / 被 OOM Kill

**识别特征**：日志里出现 `Killed process 1234 (node)`，服务毫无预兆地消失，dmesg 里有 `Out of memory: Killed process`。

#### 排查步骤

```bash
# 步骤 1：确认是不是 OOM（最直接的证据）
sudo dmesg -T | grep -iE 'out of memory|oom-killer|killed process'
# 典型输出：
# [Tue Oct 14 09:12:33 2026] Memory cgroup out of memory: Killed process 2841 (node) total-vm:...

# 或者
sudo journalctl -k --since "1 hour ago" | grep -i oom

# 步骤 2：当前内存状况
free -h
#              total   used   free   shared  buff/cache  available
# Mem:           15Gi   14Gi  200Mi       12Mi       1.1Gi       800Mi
#                                                          ↑ 看这个，不是 free！
# buff/cache 是可回收的缓存，available 才是真正能用的

# 步骤 3：谁吃了内存
ps aux --sort=-%mem | head -15
# RSS 列是实际物理内存占用（单位 KB）

# 步骤 4：是否有内存泄漏（重点）
# 同一个进程，看 RSS 是否随时间单调上升
watch -n 5 'ps -o pid,rss,etime,cmd -p $(pgrep -f api-server1 | head -1)'
# 观察 10 分钟，RSS 一直涨不降 → 内存泄漏

# 步骤 5：有没有开 swap（没 swap 时 OOM 会来得非常突然）
swapon --show
free -h | grep Swap
# Swap 全 0 → 建议加 swap，8G 机器配 2-4G swap 能显著降低 OOM 概率
```

#### 应急处置

```bash
# 1. 找出并杀掉吃内存的元凶
ps aux --sort=-%mem | head -10
sudo kill <PID>     # 先优雅退出

# 2. 临时缓解：手动清理页缓存（能立刻腾出一些内存）
sync
sudo echo 3 | sudo tee /proc/sys/vm/drop_caches
# 3 是同时清 pagecache + dentry + inode
# ⚠️ 只作应急，会导致下次读写变慢（缓存要重建），不要当常规操作

# 3. 调整服务的内存上限（systemd 版）
sudo systemctl edit api-server1
# [Service]
# MemoryMax=1G          # 硬限制，超了被杀
# MemoryHigh=800M       # 软限制，超了开始回收
# sudo systemctl daemon-reload && sudo systemctl restart api-server1

# 4. 加 swap（永久方案之一）
sudo fallocate -l 4G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

#### 根治方向

- Node 项目：`node --max-old-space-size=1536`（限制 V8 堆大小，让它早点报错而不是被系统杀）
- 查内存泄漏：`npm i -g clinic` 或用 `0x` 做火焰图
- 检查是否有无界缓存 / 无界数组增长

---

### 3.7 CPU 打满 / load 飙高

#### 排查步骤

```bash
# 步骤 1：load 是多少，核数是多少
uptime
nproc
# load average: 4.82, 4.91, 4.75，nproc = 2
# → load 是核数的 2.4 倍，严重过载

# 步骤 2：CPU 真的用满了吗（区分 CPU 瓶颈 vs IO 瓶颈）
top -bn1 | grep '%Cpu'
# 97% us, 2% sy, 0% id → 确实 CPU 满
# 5% us, 90% id, 5% wa → CPU 空闲，是别的瓶颈（比如 IO 或锁等待）

# 步骤 3：谁在吃 CPU
top -bn1 | head -15
ps aux --sort=-%cpu | head -15

# 步骤 4：是哪个进程（区分多进程 vs 单进程多线程）
# 选两个 PID，看 their %CPU 的累加
top -bn1 | head -15
# 逻辑核满但单进程 %CPU 不高 → 多进程/多线程总量问题（比如大量 node worker）
# 单进程 %CPU 就接近 100*nproc → 真正的计算热点

# 步骤 5：进程内部在忙什么（最关键的一步）
# 方法 1：top 的 HMP 模式，按 f 或 F6 添加字段，然后按 c 看完整命令行
top
#   → 按 1：显示每个逻辑核
#   → 按 H：显示所有线程
#   → 按 c：显示完整命令
#   → 按 K：勾选线程（多核排查必备）

# 方法 2：抓火焰图（最精确）
sudo npm i -g 0x
sudo 0x ~/nginx-project/backend/api-server1.js
# 浏览器打开它给的 URL，火焰图里最宽的栈就是热点

# 步骤 3.5：是不是有死循环 / GC 抖动
top -bn1 | grep -i node
# 命令行里如果有 --prof 或有 GC 相关提示
# node --prof app.js && node --prof-process isolate-*.log
```

#### 应急处置

```bash
# 1. 限流：临时降低单个进程的优先级（不中断服务）
sudo renice +10 -p <PID>       # 降低优先级

# 2. 限 CPU：限制某进程最多用几个核
sudo cpulimit -p <PID> -l 50   # 最多用 50% 单核（需 apt install cpulimit）

# 3. 优雅扩容：Nginx 加机器 / Node 加 worker
```

---

### 3.8 端口被占用，服务起不来

**报错**：`Error: listen EADDRINUSE: address already in use :::4001`

#### 排查步骤

```bash
# 方法 1：ss（最快，不需要 sudo 也能看自己的进程）
sudo ss -tlnp | grep ':4001'

# 方法 2：lsof
sudo lsof -i :4001

# 方法 3：fuser
sudo fuser -v 4001/tcp

# 方法 4：直接问内核
sudo ss -tlnp 'sport = :4001'

# 确认是不是 TIME_WAIT 堆积导致的假占用
ss -ant | grep 4001 | awk '{print $1}' | sort | uniq -c
```

#### 处置

```bash
# 情况 A：旧进程还在跑
ps -p <PID> -o pid,cmd
kill <PID>              # 先优雅退出
sleep 3
ps -p <PID> || echo "已退出"

# 情况 B：进程僵死但端口未释放（真死了但没走正常流程）
sudo kill -9 <PID>

# 情况 C：确认没人用了，直接杀
sudo fuser -k 4001/tcp

# 情况 D：只是 TIME_WAIT，内核没释放端口
# TIME_WAIT 正常持续 60 秒，等一等就好
# 确实需要复用端口（高频短连接的 TCP 服务）才调：
#   sudo sysctl -w net.ipv4.tcp_tw_reuse=1
#   echo 'net.ipv4.tcp_tw_reuse=1' | sudo tee -a /etc/sysctl.conf
```

> **预防**：systemd 里加 `PIDFile` 或用 `Type=forking` 配合 PID 文件，
> 或者用 socket 激活（`.socket` unit），让 systemd 精确管理生命周期。

---

### 3.9 403 Forbidden 权限问题

**本项目高频点**：`root` 指向的目录不对，或者 `www-data` 用户读不到文件。

#### 排查步骤

```bash
# 步骤 1：Nginx 实际用什么身份在跑
ps -o user,group,pid,cmd -C nginx
# 通常是 www-data

# 步骤 2：root 指向的目录存在吗
sudo nginx -T | grep -E 'root|alias'
# 输出是配置的绝对路径

# 步骤 3：目录链路上每一级 www-data 都能进吗（执行位！）
namei -l /home/ubuntu/nginx-project/frontend/index.html
# 每一级都必须对 other 有 x（执行）权限
# 典型坑：/home/ubuntu 是 drwx--x--x 还好，
#          但如果是 drwx------ www-data 就进不去

# 步骤 4：文件权限
ls -la /home/ubuntu/nginx-project/frontend/index.html
# 644 是标准可读

# 步骤 5：SELinux（Ubuntu 没有，但 CentOS 有，新手常混淆）
getenforce 2>/dev/null || echo "Ubuntu，无 SELinux，跳过"

# 步骤 6：Ubuntu 的 AppArmor
sudo aa-status | grep nginx
```

#### 修复

```bash
sudo chmod 755 /home/ubuntu                       # 家目录需要 others 有 x
sudo chown -R www-data:www-data /var/www/html     # 或统一 chown
sudo chmod 644 /var/www/html/index.html

# 验证：模拟 www-data 身份去读
sudo -u www-data cat /var/www/html/index.html > /dev/null && echo "可读"
```

---

### 3.10 磁盘 IO 高、响应变慢

```bash
# 安装 sysstat（iostat/sar/mpstat 都来自这个包）
sudo apt install -y sysstat

# 步骤 1：磁盘饱和度
iostat -x 1 3
# %util  接近 100% → 设备完全饱和
# await   > 20ms   → 严重延迟
# %iowait 高而 %user 低 → 瓶颈在 IO 不在 CPU

# 步骤 2：哪个进程在读写（需要 sudo）
sudo iotop -oPa          # iotop 不是默认装的：sudo apt install -y iotop
# 或者
sudo pidstat -d 1 3

# 步骤 3：是不是在做大量小 IO（对 SSD 是灾难）
iostat -x 1 | grep -E 'r/s|w/s'
# r/s 和 w/s 都是几千 → 随机小 IO，考虑换 SSD 或调大 block size

# 步骤 4：内存是否够（内存不足会导致频繁换页 → 磁盘 IO 飙升）
vmstat 1 3
# si  so    bi    bo
#  0   0     0     0   ← 正常
# 非 0 → 在 swap，磁盘 IO 高是内存不足的连锁反应

# 步骤 5：磁盘本身的健康度（SMART）
sudo apt install -y smartmontools
sudo smartctl -a /dev/vda | grep -E 'Reallocated|SMART overall'
# Reallocated_Sector_Ct > 0 → 硬盘开始坏块了，快换

# 步骤 6：历史趋势（看是不是突发）
sar -d -f /var/log/sysstat/sa14 -s 10:00:00 -e 11:00:00
```

#### 常见根因与对策

| 现象 | 根因 | 对策 |
|---|---|---|
| `%iowait` 高 + `vmstat` 的 si/so 非 0 | 内存不足导致换页 | 加内存 / 加 swap |
| `%iowait` 高 + r/s 上万 | 大量小文件随机读 | 换 SSD / 用 tmpfs 缓存热数据 |
| 某进程 w/s 极高 | 日志同步写盘 | 日志异步化 / logrotate 生效检查 |
| `%util` 100 但 `await` 也不高 | 队列积压 | 限流 |

---

### 3.11 连接数耗尽 / Too many open files

**报错**：
- Nginx：`worker_connections are not enough`
- 应用：`Error: EMFILE: too many open files`

#### 排查步骤

```bash
# 步骤 1：进程实际打开的文件数
sudo lsof -p <PID> | wc -l
# 和上限对比：
cat /proc/<PID>/limits | grep files
# "Max open files  1024  4096  4096" ← 软限制 1024，偏低

# 步骤 2：系统级上限
cat /proc/sys/fs/file-max                  # 系统总上限（很大，一般不是瓶颈）
ulimit -n                                  # 当前 shell 的软限制
ulimit -Hn                                 # 硬限制

# 步骤 3：TCP 连接状态
ss -s
# 或分类统计
ss -ant | awk '{print $1}' | sort | uniq -c | sort -rn
# TIME_WAIT 几万 → 短连接太多，考虑 HTTP keepalive / 连接池复用

# 步骤 4：Nginx 侧配置
sudo nginx -T | grep -E 'worker_connections|worker_rlimit|worker_processes'
# 公式：最大并发 = worker_processes × worker_connections
# 默认 worker_processes = auto（= 核数）
# 注意：worker_rlimit_nofile 会覆盖 worker_connections 的上限
```

#### 修复

```bash
# 临时（当前 shell）
ulimit -n 65535

# 永久：limits.conf
sudo nano /etc/security/limits.conf
# *  soft  nofile  65535
# *  hard  nofile  65535
# 改完重新登录生效；服务需要重启才能继承

# systemd 服务专用（更精确）
sudo systemctl edit nginx
# [Service]
# LimitNOFILE=65535

# Nginx 配置
# 在 nginx.conf 的顶层（http 块外面）：
#   worker_processes auto;
#   worker_rlimit_nofile 65535;
# events {
#   worker_connections 8192;
# }
sudo nginx -t && sudo systemctl reload nginx

# 系统整体上限也确认一下
echo "fs.file-max = 2097152" | sudo tee -a /etc/sysctl.conf && sudo sysctl -p
```

---

## 第 4 章 日志分析速查

### 4.1 三类日志的分工

| 日志 | 位置 | 记录什么 | 排障时看什么 |
|---|---|---|---|
| 访问日志 | `/var/log/nginx/access.log` | 谁访问了什么、状态码、耗时 | 5xx 集中在哪个 URL |
| 错误日志 | `/var/log/nginx/error.log` | Nginx 内部错误、上游失败详情 | **502/504 的直接原因** |
| 应用日志 | `journalctl -u <服务名>` | 程序自己的 stdout/stderr | 崩溃 stack trace |

**排查 502/504 时，90% 的答案在 Nginx error.log 里，不用猜。**

### 4.2 Nginx 错误关键词速查

```bash
sudo tail -1000 /var/log/nginx/error.log > /tmp/err.txt

# 按错误类型分类统计
grep -oE '\(([0-9]+):[^)]+\)' /tmp/err.txt | sort | uniq -c | sort -rn
# 输出示例：
#   152 (111:Connection refused)   ← 连接被拒 152 次 → upstream 没在监听
#    47 (110:Connection timed out) ← 超时
#     3 (104:Connection reset by peer)

grep -oE '(connect\(\) failed|upstream timed out|no live upends|too many open files|permission denied|no route to host)' /tmp/err.txt | sort | uniq -c
```

| 日志关键词 | 含义 | 处理 |
|---|---|---|
| `connect() failed (111: Connection refused)` | 端口没人监听 | 起后端 / 改对端口 |
| `connect() failed (113: No route to host)` | 网络不通 | 查路由、防火墙、安全组 |
| `upstream timed out` | 后端响应慢 | 找慢因，或调 `proxy_read_timeout` |
| `recv() failed (104: Connection reset by peer)` | 后端把连接断了 | 后端崩溃/连接池耗尽 |
| `no live upstreams` | upstream 全部不可用 | 后端全挂了 |
| `too many open files` | 句柄不够 | 调 `worker_rlimit_nofile` / `ulimit` |
| `worker_connections are not enough` | 并发连接上限 | 调 `worker_connections` |
| `permission denied` | 文件权限 | `chmod` / `chown` |
| `client intended to send too large body` | 请求体超限 | 调 `client_max_body_size` |

### 4.3 访问日志分析（找出问题接口）

```bash
LOG=/var/log/nginx/access.log

# 状态码分布
awk '{print $9}' $LOG | sort | uniq -c | sort -rn

# 5xx 集中在哪些 URL
awk '$9 ~ /^5/ {print $7}' $LOG | sort | uniq -c | sort -rn | head -20

# 哪些 IP 在疯狂请求（判断是攻击还是正常用户）
awk '{print $1}' $LOG | sort | uniq -c | sort -rn | head -20

# 每个 URL 的平均耗时（需要 log_format 里有 $request_time）
awk '{print $NF, $7}' $LOG | sort -rn | head -20

# 5xx 按小时统计（判断是突发还是持续）
awk '$9 ~ /^5/ {print substr($4,2,14)}' $LOG | uniq -c
```

**建议在 Nginx 里加上耗时日志**，否则无法定位慢请求：

```nginx
# 在 http {} 块里定义
log_format timing '$remote_addr [$time_local] "$request" '
                  '$status $body_bytes_sent rt=$request_time '
                  'urt=$upstream_response_time uct=$upstream_connect_time '
                  'us=$upstream_status ua=$upstream_addr';

# 然后在 server / location 里用它
access_log /var/log/nginx/access.log timing;
```

有了这个格式，`rt` 是总耗时，`urt` 是后端耗时。`rt` 大但 `urt` 小 → 问题在 Nginx/网络；两者都大 → 问题在后端。一眼就能分层。

### 4.4 日志轮转

```bash
# 检查是否配了轮转
ls /etc/logrotate.d/
sudo cat /etc/logrotate.d/nginx

# dry-run：看会做什么但不执行（安全）
sudo logrotate -d /etc/logrotate.d/nginx

# 强制执行
sudo logrotate -f /etc/logrotate.d/nginx
```

> **踩坑提醒**：`logrotate` 只是把日志改名成 `.log.1`，
> 但原来持有文件描述符的进程还在往老文件写。
> 所以 `postrotate` 里必须有 `nginx -s reopen` 之类让它重开文件。
> 没有这行，日志会"停止更新"，很多人以为是服务挂了。

---

## 第 5 章 三个完整实战案例

### 案例一：接口偶发 502，50% 失败率

**现象**：用户反馈下单接口时好时坏，Nginx 日志里 502 和 200 各占一半。

#### 第 1 步：定层

```bash
# 三种打法对比
curl -s http://127.0.0.1:4001/api/user    # 直连 A
curl -s http://127.0.0.1:4002/api/user    # 直连 B
curl -s http://127.0.0.1/api/user          # 走 Nginx

# 结果：直连 4001 通，直连 4002 通，走 Nginx 一次成功一次 502
# → 指向 L2/L3：Nginx 转发层
```

#### 第 2 步：看 Nginx 错误日志（直接给答案）

```bash
sudo tail -50 /var/log/nginx/error.log
# [error] 2841#2841: *12345 connect() failed (111: Connection refused)
#   while connecting to upstream, client: 1.2.3.4,
#   upstream: "http://127.0.0.1:4002/api/order"
#                              ↑ 明确指出是 4002 失败
```

#### 第 3 步：为什么 4002 会"时好时坏"

```bash
ss -tlnp | grep 4002
# 空！4002 根本没在监听

systemctl status api-server2 --no-pager
# Active: activating (auto-restart)   ← 正在自动重启
# Main process exited, code=exited, status=1

journalctl -u api-server2 -n 30 --no-pager
# [ServerB] API 服务器已启动，监听端口 4002
# Error: listen EADDRINUSE: address already in use :::4002
#                            ↑ 端口被占，但它又立刻退出
```

**根因定位**：有个僵尸进程占着 4002 端口，新的 api-server2 起不来；偶尔僵尸进程退出，新的服务抢到端口成功启动一会儿，然后又崩。表现出来就是 50% 成功率。

#### 第 4 步：找僵尸进程

```bash
sudo lsof -i :4002
# COMMAND  PID  USER   NAME
# node    10233 ubuntu node

ps -p 10233 -o pid,ppid,etime,cmd
#  PID   PPID ELAPSED CMD
# 10233  10230   5:12 node /home/ubuntu/nginx-project/backend/api-server2.js
#                        ↑ 看起来就是个正常的服务

# 但 systemd 说它没起来？看 PPID
ps -p 10230 -o pid,cmd
# PID   CMD
# 10230 /usr/bin/node ...  ← 它自己是个 node？不对
```

再深挖：
```bash
sudo lsof -p 10233 | grep cwd
# cwd  /home/ubuntu/nginx-project/backend   目录是对的
# 继续查它属于哪个 unit
systemctl status $(cat /proc/10233/cgroup | grep -o '[a-z0-9-]*\.service' | head -1)
```

或者更简单粗暴但有效：
```bash
# 从启动时间判断：systemd 里有没有第二份配置在管它
systemctl list-units --type=service --all | grep -i api
# 可能有一份手写的 nohup 进程占着，另一个 systemd 反复抢端口
```

#### 第 5 步：修复

```bash
# 杀掉不在管理下的僵尸进程
sudo kill 10233
sleep 2
sudo lsof -i :4002 || echo "端口已释放"

# 重新启动并观察
sudo systemctl restart api-server2
sleep 5
systemctl status api-server2 --no-pager | head -5
journalctl -u api-server2 -n 20 --no-pager

# 验证
for i in $(seq 1 10); do
  curl -s http://127.0.0.1/api/order | grep -o '"server":"[^"]*"'
done
# 全部正常返回，A/B 交替
```

#### 第 6 步：复盘与预防

- **根因**：管理方式混乱（systemd + nohup 双重管理），端口冲突
- **预防**：
  ```bash
  # 统一用 systemd，禁止 nohup
  # 部署脚本里加端口检查
  ss -tlnp | grep -q ':4002' && echo "警告：4002 已被占用"
  # 用 Type=forking + PIDFile 让 systemd 精确管理
  ```

---

### 案例二：磁盘 100% 导致服务无法启动

**现象**：早上一上班，发现下单接口全挂，Nginx 返回 502。

#### 第 1 步：按第 1 章的表快速定层

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1/api/user
# 502
curl -s http://127.0.0.1:4001/api/user
# curl: (7) Failed to connect to 127.0.0.1 port 4001: Connection refused
# → 指向 L4：应用没起来
systemctl status api-server1 --no-pager
# Main process exited, code=203/EXEC   ← 或者 status=1
```

#### 第 2 步：应用起不来了，看日志

```bash
journalctl -u api-server1 -n 30 --no-pager
# [error] Error: EACCES: permission denied, open '/var/log/nginx-project/app.log'
#   → 权限问题？但磁盘满也会导致写文件失败
```

#### 第 3 步：查磁盘（关键转折点）

```bash
df -h
# /dev/vda1        20G  20G     0  100% /     ← 满了

df -i
# /dev/vda1  1310720 1310720     0  100% /    ← inode 也满了
```

**inode 100% 但空间还有剩余**，说明是海量小文件把 inode 吃光了。

#### 第 4 步：定位

```bash
sudo du -h --max-depth=1 /var 2>/dev/null | sort -rh | head
# 15G  /var/log

sudo du -h --max-depth=1 /var/log | sort -rh | head
# 12G  /var/log/nginx
# 2.0G /var/log/journal

sudo ls -lah /var/log/nginx/ | head -20
# -rw-r-----  1 www-data www-data 4.0G Oct 14 09:02 access.log
# -rw-r-----  1 www-data www-data 8.1G Oct 10 22:14 error.log.5
#              ↑ 单个 8G 的轮转文件，说明 logrotate 早就没在跑了

sudo cat /etc/logrotate.d/nginx
# 配置里有 daily rotate 7 —— 但没生效！

# 为什么没生效？看 systemd timer
systemctl status logrotate.timer --no-pager
systemctl list-timers | grep logrotate
# 可能是 timer 没启用
```

#### 第 5 步：应急清理

```bash
# 1. 先确认 journal 占多少
journalctl --disk-usage
# Archived and active journals take up 2.0G

# 2. 清理（保留最近 3 天）
sudo journalctl --vacuum-time=3d
# Deleted 1.8G of archived journals

# 3. 清理已轮转的旧 nginx 日志（保留最近3份）
sudo ls -t /var/log/nginx/*.gz /var/log/nginx/error.log.[0-9]* 2>/dev/null \
  | tail -n +4 | xargs -r sudo rm -f
# 只删 error.log.4 及更早的

# 4. 验证空间释放
df -h /
df -i /
```

#### 第 6 步：服务恢复

```bash
sudo systemctl restart api-server1 api-server2
sleep 3
systemctl is-active api-server1 api-server2
curl -s http://127.0.0.1/api/user | head -c 100
```

#### 第 7 步：永久修复

```bash
# 1. 修 journal 上限
sudo nano /etc/systemd/journald.conf
# [Journal]
# SystemMaxUse=500M
sudo systemctl restart systemd-journald

# 2. 修 logrotate
sudo nano /etc/logrotate.d/nginx
# /var/log/nginx/*.log {
#     daily
#     rotate 7
#     compress
#     missingok
#     notifempty
#     create 0640 www-data adm
#     sharedscripts
#     postrotate
#         [ -f /run/nginx.pid ] && kill -USR1 `cat /run/nginx.pid`
#     endscript
# }
#   ↑ postrotate 里用 USR1 信号让 nginx 重开日志文件（比 -s reopen 更可靠）

sudo logrotate -d /etc/logrotate.d/nginx    # dry-run 验证语法
sudo systemctl restart logrotate.timer        # 确保 timer 跑起来
systemctl list-timers | grep logrotate        # 确认下次执行时间

# 3. 加磁盘监控（避免下次还是被撑爆）
sudo apt install -y prometheus-node-exporter   # 或者简单点用 cron
```

**加一条磁盘告警 cron**：
```bash
crontab -e
# 每 10 分钟检查，低于 15% 就告警
*/10 * * * * df -h / | awk 'NR==2 {gsub("%","",$5); if ($5+0 > 85) system("logger -t disk-alert DISK USED " $5 "%")}'
```

---

### 案例三：服务反复重启，罪魁祸首是磁盘满 + OOM

**现象**：监控告警 api-server1 每分钟重启一次，业务间歇性失败。

#### 第 1 步：确认重启循环

```bash
systemctl show api-server1 -p NRestarts
# NRestarts=47     ← 确认

systemctl status api-server1 --no-pager
# Active: activating (auto-restart)
# Main process exited, code=killed, status=9/KILL
#                    ↑ 注意：不是 exited，是 killed！
#                      这意味着是被信号杀的，不是程序自己退的
```

**关键判断**：`exited` 是程序自己退出（看应用日志），`killed` 是被外部杀死（看内核日志和资源）。

#### 第 2 步：分头查两个方向

```bash
# 方向 A：是不是 OOM？
sudo dmesg -T | grep -iE 'out of memory|oom-killer|killed process'
# [Tue Oct 14 09:12:33 2026] Memory cgroup out of memory: Killed process 2841 (node)
#   total-vm:4820308kB, anon-rss:1204532kB, file-rss:0kB
#             ↑ 用了 1.2G 物理内存被杀

# 方向 B：是不是磁盘满导致的连锁反应？
df -h /
# /dev/vda1  20G  20G  0  100% /
```

**两个都中了。**

#### 第 3 步：理解因果链

```
磁盘 100%
   ↓
Node 启动时写日志失败 → 抛异常 → 进程退出
   ↓
systemd 3 秒后重启 → 反复失败
   ↓
内存中大量对象无法回收（cgroup 限制内堆在 1.2G）
   ↓
触发 cgroup memory limit → OOM Killer 杀进程
   ↓
表现为：进程被杀 → 重启 → 再被杀……循环
```

#### 第 4 步：止损 + 修复

```bash
# 1. 立刻止血：停止重启风暴
sudo systemctl stop api-server1

# 2. 清理磁盘（见案例二）
sudo journalctl --vacuum-size=200M
sudo apt clean

# 3. 检查内存上限配置
systemctl show api-server1 -p MemoryMax
# MemoryMax=infinity    ← 没限制
systemctl cat api-server1 | grep -i memory
# 没有 MemoryMax

# 4. 恢复服务
sudo systemctl start api-server1
sleep 5
systemctl show api-server1 -p NRestarts    # 不再增长
curl -s http://127.0.0.1:4001/api/user
```

#### 第 5 步：加防护栏（避免下次复发）

```bash
# 1. 给服务加内存上限，让它提前失败而不是被系统杀
sudo systemctl edit api-server1
# [Service]
# MemoryMax=1500M
# MemoryHigh=1200M
# Restart=on-failure
# RestartSec=10
# StartLimitIntervalSec=300
# StartLimitBurst=3
#   ↑ 重要！5 分钟内重启超过 3 次就放弃，不再无限重启
#     这是 systemd 的启动频率限制，是防重启风暴的最后一道防线

sudo systemctl daemon-reload
sudo systemctl reset-failed api-server1
sudo systemctl restart api-server1

# 2. 验证限流生效
systemctl show api-server1 -p StartLimitBurst

# 3. Node 层限制堆大小（让 V8 主动报错并打印 stack，而不是静默被 kill）
sudo systemctl edit api-server1
# [Service]
# ExecStart=
# ExecStart=/usr/bin/node --max-old-space-size=1024 api-server1.js
#   ↑ 注意：改 ExecStart 必须先清空（写空的 ExecStart=），
#     否则 systemd 会认为是"追加命令"

sudo systemctl daemon-reload && sudo systemctl restart api-server1

# 4. 加磁盘水位监控告警（见案例二）
```

**这个案例的核心启示**：`code=killed, status=9/KILL` 是排查的分水岭。
- `exited` → 看应用日志（程序自己的问题）
- `killed` → 看资源（内核/OOM/cgroup）和外部干预

---

## 第 6 章 应急处置 vs 根因修复

**出事的第一个小时该做什么**，按这个优先级：

```bash
# ========== 第 1-5 分钟：止血 ==========

# 1. 确认影响面（是全部用户还是部分？全部接口还是个别？）
#    查 access.log 的状态码分布

# 2. 能回滚就先回滚（最快恢复）
#    Nginx: sudo cp sites-available/nginx-app.bak sites-available/nginx-app
#           sudo nginx -t && sudo systemctl reload nginx
#    应用: git checkout v1.2.0 && sudo systemctl restart api-server

# 3. 不能回滚就先降级
#    摘掉故障节点（Nginx upstream）
sudo nano /etc/nginx/sites-available/nginx-app
#   upstream api_backend {
#       server 127.0.0.1:4001 max_fails=0;   # 临时全打到一个健康节点
#       # server 127.0.0.1:4002 down;        # 下线故障节点
#   }
sudo nginx -t && sudo systemctl reload nginx

# 4. 实在不行就临时扩容
#    起一个备用进程顶上

# ========== 第 5-30 分钟：定位 ==========
# 跑第 2 章的现场采集脚本
# 按第 1 章六层法逐层排除

# ========== 30 分钟以后：根因修复 ==========
# 改代码 / 改配置 / 加监控
# 必须有对应的测试或灰度验证
```

**绝对不要做的事**：

| ❌ 别做 | 为什么 |
|---|---|
| 连续 `restart` 试图"碰碰运气" | 销毁现场，且可能掩盖间歇性问题 |
| 一次改多个地方 | 无法归因，下次复发还是懵 |
| 直接 `rm -rf` 清理"看起来很大"的目录 | 可能删掉正在用的数据 |
| 在生产上 `vim` 改配置文件 | 语法错误会导致服务起不来，且没有回滚 |
| 忽略 `/var/log` 的历史日志 | 轮转后的日志（`*.gz`）是重要证据 |

---

## 第 7 章 排障记录模板

每次线上故障都留一份记录，这是团队最有价值的资产。

```markdown
# 故障报告：<一句话描述>

## 摘要
- 现象：
- 影响面：X 个用户 / X% 请求失败 / 持续 X 分钟
- 根因：
- 修复用时：X 分钟

## 时间线
| 时间 | 动作 | 结果 |
|---|---|---|
| 09:12 | 收到告警 | |
| 09:15 | 现场采集，判断是 L4 应用层 | |
| 09:25 | 定位到 4002 端口冲突 | |
| 09:40 | 清理僵尸进程，恢复服务 | |

## 现象详情
（错误日志原文、状态码、截图）

## 排查过程
1. 
2. 
3. 

## 根因分析
- 直接原因：
- 深层原因（为什么会有这个直接原因）：

## 修复措施
- 应急处置：
- 永久修复：

## 后续改进项
| 改进项 | 类型 | 负责人 | 状态 |
|---|---|---|---|
| 服务加 StartLimitBurst | 加固 | | |
| journal 日志加容量上限 | 加固 | | |

## 复盘问题
- 为什么没更早发现？（监控缺口）
- 为什么恢复花了 X 分钟？（工具/流程缺口）
- 怎么避免复发？
```

---

## 第 8 章 预防性 checklist

**故障不发生最好，但发生了不扩大、恢复快也很重要。**

### 部署前

- [ ] `sudo nginx -t` 语法检查通过
- [ ] 新配置先备份，有回滚方案
- [ ] 端口没有冲突（`ss -tlnp` 检查）
- [ ] systemd unit 的 `User` / `WorkingDirectory` / `ExecStart` 三项都存在
- [ ] 加了 `Restart=on-failure` 和 `StartLimitBurst=3`（防重启风暴）
- [ ] 灰度发布：一台一台切，出问题立刻回滚

### 运行中

- [ ] 磁盘告警（<15% 触发）
- [ ] 内存告警（available < 15% 触发）
- [ ] 服务存活探测（`curl` 健康检查接口，失败自动告警）
- [ ] 证书到期监控（HTTPS 必须）
- [ ] 日志轮转已生效（`logrotate.timer` 在跑）
- [ ] `journalctl --vacuum-*` 定时任务

### 每周例行检查（10 分钟）

```bash
# 一次跑完
echo "=== 失败的 systemd 服务 ==="   && systemctl --failed --no-pager
echo "=== 磁盘 ==="                  && df -h | grep -v tmpfs
echo "=== 内存 ==="                  && free -h
echo "=== 端口占用是否符合预期 ==="   && ss -tlnp
echo "=== 日志占用 ==="              && journalctl --disk-usage
echo "=== 日志轮转是否生效 ==="      && ls -la /var/log/nginx/ | head
echo "=== 最近的服务重启 ==="        && systemctl show api-server1 -p NRestarts
echo "=== Nginx 配置检查 ==="        && sudo nginx -t
```

---

## 附：配套实验脚本

仓库里的 `deploy/lab-troubleshoot.sh` 可以**亲手把环境搞坏**，用来练习本文的每一条排查路径。

```bash
# 查看所有可注入的故障场景
bash deploy/lab-troubleshoot.sh list

# 注入一个故障（会提示你将要做什么）
bash deploy/lab-troubleshoot.sh inject 502

# 排查完之后还原
bash deploy/lab-troubleshoot.sh restore

# 拿参考答案（建议自己先排查完再看）
bash deploy/lab-troubleshoot.sh answer 502
```

**推荐练习顺序**：

| 场景 | 练什么 | 难度 |
|---|---|---|
| `502` | 六层定位法、日志阅读 | ⭐ |
| `perm` | 权限排查、`namei -l` | ⭐ |
| `disk` | 磁盘定位与安全清理 | ⭐⭐ |
| `oom` | 内存分析、OOM 识别 | ⭐⭐ |
| `port` | 端口冲突处置 | ⭐ |
| `badconf` | Nginx 配置错误、语法检查 | ⭐⭐ |
| `restart-loop` | systemd 退出码、启动循环 | ⭐⭐⭐ |
| `timeout` | 504 排查、耗时分析 | ⭐⭐ |

> ⚠️ **建议在 WSL 或测试机上演练**，不要在生产服务器上跑 inject。