# Ubuntu 运维指令详细教程

> 结合本项目（Nginx + 两个 Node 后端）编写，所有命令都可以直接复制到 Ubuntu / WSL 里练。  
> 建议边看边敲，每条命令都亲手执行一次。

---

## 目录

1. [系统信息查看](#1-系统信息查看)
2. [文件与目录操作](#2-文件与目录操作)
3. [权限体系](#3-权限体系)
4. [用户与sudo](#4-用户与-sudo)
5. [进程管理](#5-进程管理)
6. [网络排查](#6-网络排查)
7. [systemd 服务管理](#7-systemd-服务管理)
8. [日志查看](#8-日志查看)
9. [磁盘与内存](#9-磁盘与内存)
10. [文本处理三剑客](#10-文本处理三剑客)
11. [压缩与解压](#11-压缩与解压)
12. [软件包管理 apt](#12-软件包管理-apt)
13. [Shell 效率技巧](#13-shell-效率技巧)
14. [本项目实战演练](#14-本项目实战演练)
15. [故障排查决策树](#15-故障排查决策树)
16. [速查表](#16-速查表)
17. [命令全称与参数拆解](#17-命令全称与参数拆解)

---

## 1. 系统信息查看

### 1.1 基础信息

```bash
uname -a                    # 内核版本、架构、主机名
hostname                    # 主机名
lsb_release -a              # LSB = Linux Standard Base；release = 发行版信息；-a = all（全部）
cat /etc/os-release         # cat = concatenate（连接并输出文件内容）；查看系统发行版信息
uptime                      # 开机时长 + 负载均值
date                        # 当前时间
timedatectl                 # 时区、时间同步状态（WSL 常用）
whoami                      # 当前用户名
id                          # 用户 id + 所属组
```

拆开看 `cat /etc/os-release`：`cat` 会把指定文件内容输出到终端；`/etc` 是系统配置目录，`os-release` 是记录操作系统发行版信息的文件名。这里的 `cat` 是 `concatenate` 的缩写/来源，不是按字母拼出的缩写词。

### 1.2 硬件信息

```bash
lscpu                       # CPU 详细信息（核心数、架构）
nproc                       # 只显示 CPU 逻辑核心数
free -h                     # 内存使用（-h 人类可读格式）
lsblk                       # 块设备（磁盘、分区）树状图
lspci | less                # PCI 设备（网卡、显卡）
lsusb                       # USB 设备
dmidecode | less            # 硬件详细信息（需root）
```

**关键区别**：`nproc` 显示的是**逻辑核心数**（比如 8 核 16 线程会显示 16），  
而 `lscpu` 里能看到物理核心和线程的对应关系。压测时搞清楚这个很重要。

### 1.3 负载含义（重点）

```bash
uptime
#  15:32:01 up 2days3:14,  1 user,  load average: 0.52, 0.58, 0.59
#                                    ↑                ↑  ↑  ↑
#                                当前用户         1分钟 5分钟 15分钟
```

load average 三个数字的含义：

| 值        | 含义 | 判断标准        |
| -------- | -- | ----------- |
| < 1      | 空闲 | CPU 还有余量    |
| 1 ~ 4    | 繁忙 | 正常范围，队列在排队  |
| > CPU 核数 | 过载 | 进程在排队等待 CPU |

**注意**：load average 统计的是**可运行状态 + 不可中断状态**的进程数。  
IO 密集型操作（比如大量磁盘读写）也会拉高这个值，即使 CPU 空闲。

---

## 2. 文件与目录操作

### 2.1 路径概念

```bash
pwd                # 当前工作目录 (print working directory)
cd /                # 根目录
cd ~                # 当前用户的家目录 (/home/用户名)
cd -                # 回到上一个目录（超常用）
cd ..               # 上一级目录
```

### 2.2 目录结构速记

```
/                根目录，整个文件系统的起点
├── /home       普通用户的家目录
├── /root       root 用户的家目录
├── /etc        系统配置文件（nginx.conf 就在这附近）
├── /var        运行时变化的数据（日志、缓存、数据库）
│   └── /var/log  日志文件
├── /tmp        临时文件，重启即清空
├── /usr        用户程序和库文件（/usr/bin 放命令）
│   └── /usr/local 手动安装的软件
├── /opt        第三方软件安装目录
├── /proc       虚拟文件系统，进程信息在这里
└── /mnt        挂载点（WSL 里访问 Windows 磁盘用 /mnt/c）
```

### 2.3 ls 命令详解

```bash
ls                    # 当前目录内容
ls -l /etc             # 详细信息
ls -la /etc            # 包含隐藏文件（以 . 开头）
ls -lh /etc            # 人类可读大小（1.2K 而不是 1220）
ls -lt /etc            # 按修改时间倒序（新的在前）
ls -ltr /etc           # 按时间正序（老的在前）
ls -lS /etc            # 按文件大小倒序
ls -ld /etc            # 查看目录本身属性（不是目录内容）
```

`-l` 输出的各字段含义：

```
-rw-r--r--  1 user  group  4096  Oct 8 10:30 filename
│└┬┘└┬┘└┬┘   │      │       │        │        │
│ │  │  │    │      │       │        │        └ 文件名
│ │  │  │    │      │       │        └ 最后修改时间
│ │  │  │    │      │       └ 大小（字节）
│ │  │  │    │      └ 所属组
│ │  │  │    └ 所属用户
│ │  │  └ others 权限
│ │  └ group 权限
│ └ owner 权限
└ 文件类型：- 常规 d 目录 l 链接
```

### 2.4 创建与删除

```bash
touch test.txt                    # 创建空文件
mkdir demo                         # 创建单级目录
mkdir -p a/b/c                    # 递归创建多级目录（-p 很关键）
cp file.txt file.bak              # 复制文件
cp -r dir/ dir_backup/            # 复制目录（-r 必须有）
cp -a dir/ dir_backup/            # 归档复制，保留权限/时间（推荐）
mv old.txt new.txt                # 移动或重命名
rm file.txt                       # 删除文件
rm -r dir/                        # 删除目录（-r 递归）
rmdir emptydir                    # 删除空目录（只能删空的，更安全）
```

**安全删除习惯**：

```bash
# 1. 删除前先确认内容
ls -la dir/

# 2. 先备份再删
cp -a dir/ /tmp/dir_backup/

# 3. 用 trash-cli 而不是 rm（装到回收站，可恢复）
sudo apt install trash-cli
trash-put dir/                    # 比 rm 安全得多
```

### 2.5 文件查找

```bash
find /var/log -name "*.log"              # 按文件名找
find /home -type f -mtime -7             # 7天内修改过的文件
find / -size +100M                        # 大于100M的文件
find /var -type d -name "nginx*"          # 按目录名找
find /tmp -name "*.tmp" -delete           # 找到并删除（危险！）
find /var/log -name "*.log" -exec ls -lh {} \;   # 对结果执行命令
```

### 2.6 查看文件内容

```bash
cat file.txt                 # 全部输出（大文件慎用）
less file.txt                # 分页查看（q 退出，/ 搜索，n 下一个）
head -20 file.txt            # 前20行
tail -20 file.txt            # 后20行
tail -f /var/log/syslog      # 实时跟踪（Ctrl+C 退出）
tail -F /var/log/app.log     # 文件被轮转后仍能继续跟踪（更推荐）
wc -l file.txt               # 行数统计
```

**`less` 常用快捷键**：

| 键          | 作用          |
| ---------- | ----------- |
| `j` / `↓`  | 向下翻一行       |
| `k` / `↑`  | 向上翻一行       |
| `空格` / `f` | 向下翻一页       |
| `b`        | 向上翻一页       |
| `/关键词`     | 向下搜索        |
| `?关键词`     | 向上搜索        |
| `n` / `N`  | 跳到下一个/上一个匹配 |
| `g` / `G`  | 跳到文件开头/结尾   |
| `q`        | 退出          |

---

## 3. 权限体系

### 3.1 十进制权限速记

```
4 = r 读  (read)
2 = w 写  (write)
1 = x 执行 (execute)
```

常用组合：

| 数字  | 符号        | 含义                   |
| --- | --------- | -------------------- |
| 7   | rwx       | 读、写、执行               |
| 6   | rw-       | 读、写                  |
| 5   | r-x       | 读、执行                 |
| 4   | r--       | 只读                   |
| 0   | ---       | 全部禁止                 |
| 755 | rwxr-xr-x | 目录/脚本：所有者全权，其他人可读可执行 |
| 644 | rw-r--r-- | 普通文件：所有者可改，其他人只读     |
| 600 | rw------- | 私密文件，只有所有者能访问        |

### 3.2 chmod 命令

```bash
chmod 644 file.txt              # 数字方式
chmod u+x script.sh             # 给所有者加执行权限
chmod g-w file.txt              # 去掉组的写权限
chmod -R 755 /var/www/          # 递归修改整个目录树
chmod a+r file.txt              # a = all，所有人加读权限
```

### 3.3 chown 命令

```bash
chown user:group file           # 改所有者
chown -R user:group /var/www/   # 递归改整个目录
chown user file.txt             # 只改所有者，不改组
chmod u+s /usr/bin/sudo         # 给二进制加 SUID 位
```

### 3.4 umask（新建文件的默认权限）

```bash
umask                # 查看当前掩码，通常是 0022
umask 022            # 新建文件 = 644，新建目录 = 755
umask 077            # 新建文件 = 600，新建目录 = 700（更安全）
```

**推导规则**：文件权限 = 666 - umask，目录权限 = 777 - umask。  
目录必须有执行权限才能进去，所以默认 755 而不是 644。

---

## 4. 用户与 sudo

### 4.1 sudo 常用变体

```bash
sudo command                  # 以 root 执行单条命令
sudo -i                       # 切换到 root 的完整登录环境
sudo su                       # 同上（老写法）
sudo -u www-data command      # 以指定用户执行
sudo !!                       # 用 sudo 重跑上一条命令（超常用）
sudo apt update               # 记住密码5分钟，期内不用重复输入
sudo -k                       # 立即清除缓存的密码
```

### 4.2 用户管理

```bash
sudo adduser dev              # 创建用户（会创建同名的家目录和组）
sudo adduser --system appuser # 创建系统用户（无家目录，不可登录）
sudo passwd dev               # 修改密码
sudo usermod -aG sudo dev    # 把 dev 加入 sudo 组
sudo userdel -r dev           # 删除用户并删掉家目录
sudo groupadd developers      # 创建组
sudo usermod -aG developers dev   # 加入组
sudo usermod -s /bin/bash dev     # 修改默认 shell
```

**重要**：把用户加入组后需要**重新登录**才生效。忘了这步是新手常见坑。

---

## 5. 进程管理

### 5.1 查看进程

```bash
ps aux                      # 所有进程（BSD 语法，无横线）
ps -ef                      # 所有进程（System V 语法，有横线）
ps aux --sort=-%cpu | head   # 按 CPU 排序，最占用的在前
ps aux --sort=-%mem | head   # 按内存排序
ps -p 1234                  # 查看指定 PID
ps aux | grep node          # 过滤出 node 进程（用 [n]ode 避免匹配到 grep 自己）
pgrep -a node               # 更方便的写法，直接找进程
pstree -p                   # 进程树，看父子关系
top                         # 实时监控（q 退出）
htop                        # 更友好的版本（需安装）
```

### 5.2 top 界面解读

```
top - 14:32:01 up 2 days,  3:14,  1 user,  load average: 0.52, 0.58, 0.59
Tasks: 128 total,   1 running, 127 sleeping,   0 stopped,   0 zombie
%Cpu(s):  2.1 us,  0.5 sy,  0.0 ni, 97.4 id,  0.0 wa,  0.0 hi,  0.0 si
MiB Mem :  16384.0 total,   8192.0 free,   2048.0 used,   6144.0 buff/cache
                ↑ id 是空闲比例。wa 是 IO 等待，高说明磁盘是瓶颈
```

**关键指标**：

- `load average` 超过 CPU 核数 → CPU 瓶颈
- `%wa`（IO wait）长期 > 20% → 磁盘瓶颈
- `zombie` 进程 > 0 → 有 bug（父进程没回收子进程）

### 5.3 杀死进程

```bash
kill 1234                    # 发送 SIGTERM(15)，优雅退出，让程序清理资源
kill -9 1234                 # 发送 SIGKILL(9)，强制杀死，无法清理
killall node                 # 按名字杀所有
pkill -f "node server1.js"   # 按完整命令行匹配杀
kill -TERM $(pgrep nginx)    # 批量优雅停止
```

**原则**：先用 `kill`，等几秒不管用再 `kill -9`。  
`kill -9` 会导致数据库写入中断、临时文件残留等问题。

### 5.4 前后台任务

```bash
command &                    # 放到后台运行
jobs                         # 查看当前shell的后台任务
fg %1                        # 把后台任务调到前台
bg %1                        # 让暂停的任务在后台继续
Ctrl + Z                     # 暂停当前前台任务（注意不是退出）
Ctrl + C                     # 中断当前前台任务
$?                          # 上一条命令的退出码（0成功，非0失败）
echo $?                      # 同上，写法更清晰
```

### 5.5 长驻进程（重点）

生产环境跑服务，**绝不能**直接 `node server1.js` 后关终端——终端一关进程就死了。

```bash
# 方式1：nohup（最简单）
nohup node backend/api-server1.js > logs/server1.log 2>&1 &
#                        ↑ 重定向      ↑ 记录PID     ↑ 后台
# 2>&1 意思是：把标准错误也重定向到标准输出的文件里
# 否则报错信息会丢到终端，log 里看不到

# 停止：
kill $(cat server1.pid)

# 方式2：tmux（推荐，能看能交互）
sudo apt install tmux
tmux new -s nginx            # 新建会话
# 在里面启动服务，Ctrl+B 然后按 D 脱离
tmux ls                      # 列出会话
tmux attach -t nginx         # 重新连回去
```

**tmux 常用操作**：

| 快捷键                    | 作用          |
| ---------------------- | ----------- |
| `Ctrl+B` 然后 `D`        | 脱离会话（服务继续跑） |
| `Ctrl+B` 然后 `D` 然后 `N` | 新建窗口        |
| `Ctrl+B` 然后 `C`        | 新建窗口        |
| `Ctrl+B` 然后 `方向键`      | 切换窗口        |
| `Ctrl+B` 然后 `D` 然后 `K` | 关闭当前窗口      |
| `Ctrl+B` 然后 `?`        | 查看所有快捷键     |

---

## 6. 网络排查

### 6.1 查看网络配置

```bash
ip a                          # 查看所有网卡和IP（最常用）
ip addr show eth0             # 只看某张网卡
ip -br a                      # brief 格式，更紧凑
ip route                      # 路由表，看默认网关
ip link set eth0 up           # 启用网卡
ip link set eth0 down         # 关闭网卡
hostname -I                   # 只显示本机IP
cat /etc/resolv.conf          # DNS 配置
cat /etc/hosts                # 手动域名解析（改完 sudo hosts）
```

### 6.2 查看端口监听（排查第一步）

```bash
ss -tulnp                   # TCP/UDP 监听 + 进程名（最常用）
ss -tlnp 'sport = :80'       # 只看80端口
ss -ant | grep ESTAB        # 看已建立的连接
ss -s                       # 统计概要
sudo lsof -i :80             # 看谁占用了80端口
sudo fuser -k 80/tcp         # 杀掉占用80端口的进程
```


**最常用的一条命令**：

```bash
sudo ss -tulnp | grep 80
# 输出示例：
# tcp   LISTEN  0  511  0.0.0.0:80  0.0.0.0:*  users:(("nginx",pid=1234,fd=6))
#                     ^^^^^^          ^^^^^                    ^^^^^^^^^^^^^
#                     监听地址          端口                    是哪个进程占的
```

### 6.3 连通性测试

```bash
ping -c 4 8.8.8.8           # 测试外网连通（-c 指定次数）
ping -c 4 localhost          # 测试本机
ping -c 4 your-site.com      # 测试域名解析

traceroute 8.8.8.8           # 看到底经过哪些路由跳
mtr 8.8.8.8                   # 持续 ping，显示丢包位置（需安装）

dig example.com              # 查 DNS 详细记录
dig +short example.com       # 只要 IP
nslookup example.com         # 老工具，Windows 上更常用

curl http://example.com                  # 发 GET 请求
curl -I http://example.com               # 只看响应头
curl -X POST -d '{"a":1}' -H "Content-Type: application/json" http://api   # 发POST
curl -o file.zip https://x.com/f.zip     # 下载并保存
curl -s http://localhost/api/user | jq   # 静默调用 + JSON 美化（需jq）

telnet 127.0.0.1 80          # 裸测端口通不通
nc -zv 127.0.0.1 80          # 同上，nc 更轻量
```

**排查顺序**（这个顺序很重要，从内到外）：

```bash
# 1. 服务本身起了吗？
ps aux | grep node

# 2. 端口真的在监听吗？
ss -tlnp | grep 4001

# 3. 本机能访问吗？（绕过 Nginx 直连后端）
curl -s http://127.0.0.1:4001/api/user

# 4. 本机能访问 Nginx 吗？
curl -sI http://127.0.0.1

# 5. 通过 IP 从外面访问（绕开域名解析）
curl -s http://$(hostname -I | awk '{print $1}')
```

### 6.4 WSL 特殊说明

WSL 有个坑：Windows 访问 WSL 里的服务，需要走 WSL 的 IP，不能直接用 127.0.0.1  
（取决于 WSL 版本和网络模式，最新版 WSL2 已支持 localhost 转发）。

```bash
# 在 Ubuntu 里查 IP
hostname -I
# 输出如 172.24.53.101

# 在 Windows 里访问
curl http://172.24.53.101

# 让 WSL 关机时后台服务不中断（关键配置）
# 在 Windows 的 %UserProfile%\.wslconfig 加：
# [wsl2]
# systemd=true
```

---

## 7. systemd 服务管理

现代 Ubuntu 用 systemd 管理后台服务，比老式的 init 脚本强得多。

### 7.1 核心命令

```bash
systemctl start nginx         # 启动
systemctl stop nginx          # 停止
systemctl restart nginx       # 重启（stop + start）
systemctl reload nginx        # 重新加载配置（不中断服务，优先用这个）
systemctl status nginx        # 查看状态（详细）
systemctl enable nginx        # 设置开机自启
systemctl disable nginx       # 取消开机自启
systemctl is-enabled nginx    # 查询是否自启（enabled/disabled/static）
systemctl is-active nginx     # 查询是否运行（active/inactive/failed）
systemctl daemon-reload       # 修改了 unit 文件后必须执行
systemctl list-units          # 列出所有运行的服务
systemctl list-unit-files     # 列出所有服务文件
systemctl cat nginx           # 查看服务定义和配置路径
```

### 7.2 status 输出解读

```
● nginx.service - A high performance web server and a reverse proxy server
   Loaded: loaded (/lib/systemd/system/nginx.service; enabled; vendor preset: enabled)
   Active: active (running) since Wed 2026-10-07 12:00:00 CST; 1 day 4h ago
           ↑ 运行中                        ↑ 启动时间
     Tasks: 6 (limit: 38284)
     Memory: 24.5M
   CGroup: /system.slice/nginx.service
           └─2815 nginx: worker process     ← 实际干活的进程和它的子进程
```

### 7.3 为自己的项目写 systemd 服务

这是运维最核心的能力之一。以本项目为例：

```bash
sudo tee /etc/systemd/system/api-server1.service > /dev/null << 'EOF'
[Unit]
Description=Backend API Server 1
After=network.target

[Service]
Type=simple
User=ubuntu
WorkingDirectory=/home/ubuntu/nginx-project/backend
ExecStart=/usr/bin/node api-server1.js
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# 激活配置
sudo systemctl daemon-reload
sudo systemctl enable api-server1    # 开机自启
sudo systemctl start api-server1
sudo systemctl status api-server1
```

**Unit 文件关键字段解释**：

| 字段                           | 作用                         |
| ---------------------------- | -------------------------- |
| `Type=simple`                | 主进程就是 ExecStart 那个进程       |
| `Type=forking`               | 启动后主进程退出，需要 PIDFile 指定 pid |
| `After=network.target`       | 网络就绪后再启动（必须配）              |
| `Restart=always`             | 进程挂了自动重启                   |
| `RestartSec=3`               | 重启前等3秒，避免疯狂重启打爆日志          |
| `WantedBy=multi-user.target` | 开机自启的目标级别                  |

`Restart` 的可选值：`no` / `on-success` / `on-failure` / `always` / `on-abnormal`。

**修改了 unit 文件后，流程永远是三步**：

```bash
sudo systemctl daemon-reload
sudo systemctl restart 服务名
sudo systemctl status 服务名
```

---

## 8. 日志查看

### 8.1 journalctl（systemd 日志）

```bash
journalctl -u nginx                  # 某个服务的全部日志
journalctl -u nginx -f               # 实时跟踪（最重要）
journalctl -u nginx -n 100           # 最近100行
journalctl -u nginx --since "10 min ago"
journalctl -u nginx --since today
journalctl -u nginx -p err           # 只看 error 级别
journalctl -u api-server1 --since today --no-pager
journalctl -u nginx -b                # 本次开机以来
journalctl -k                        # 内核日志（等价于 dmesg）
journalctl --disk-usage              # 日志占了多少磁盘
journalctl --vacuum-time=7d          # 清理7天前的日志
```

**日志级别从低到高**：debug < info < notice < warning < err < crit < alert < emerg

### 8.2 传统日志文件

```bash
tail -f /var/log/nginx/access.log     # 实时跟踪访问日志
tail -f /var/log/nginx/error.log      # 错误日志
grep -i "error" /var/log/nginx/error.log | tail -50    # 只看错误

# 你的 Node 服务如果用 nohup 输出
tail -f ~/nginx-project/logs/server1.log
```

### 8.3 logrotate（日志轮转）

日志不轮转会撑爆磁盘。配置在 `/etc/logrotate.d/`：

```
/home/ubuntu/nginx-project/logs/*.log {
    daily              # 每天轮转一次
    rotate 7           # 保留7份历史
    compress          # 压缩旧日志
    delaycompress     # 最近一份不压缩，方便查看
    missingok         # 文件不存在不报错
    notifempty        # 空文件不轮转
    create 0644 ubuntu ubuntu
    postrotate
        # 轮转后执行的命令，比如通知 nginx reopen 日志
        /usr/sbin/nginx -s reopen 2>/dev/null || true
    endscript
}
```

**手动触发轮转测试**：

```bash
sudo logrotate -d /etc/logrotate.d/nginx    # -d 是 dry-run，只看会做什么
sudo logrotate -f /etc/logrotate.d/nginx    # -f 强制执行
```

---

## 9. 磁盘与内存

### 9.1 磁盘空间

```bash
df -h                          # 各分区使用情况（h = human readable）
df -h /                        # 指定路径所在分区
df -i                          # inode 使用情况（文件过多但空间没满是这个原因）
du -sh /var/log/               # 目录总大小
du -h --max-depth=1 /var | sort -rh | head    # 找出谁在占空间（神器）
find / -size +1G -type f 2>/dev/null          # 找出所有超过1G的文件

# 清理旧日志（WSL 里最常见的空间问题）
sudo journalctl --vacuum-size=100M
sudo apt autoremove
sudo apt clean
```

### 9.2 内存

```bash
free -h                          # 内存概况
free -h --watch                  # 持续刷新
cat /proc/meminfo | head         # 更详细的内存信息
ps aux --sort=-%mem | head       # 谁在吃内存
```

**重要概念**：`available` 才是真正可用的内存。`free` 显示的是完全没被使用的，  
Linux 会把空闲内存拿去做缓存，`buff/cache` 那部分在需要时会自动释放。  
所以 **不要看到 `used` 很高就慌**，重点看 `available`。

### 9.3 存储和挂载

```bash
mount                                    # 所有挂载点
mount | grep /mnt/c                      # WSL 里 Windows 磁盘的挂载
lsblk                                   # 磁盘设备树
sudo fdisk -l                           # 查看分区表
sudo blkid                               # 查看UUID（写 fstab 必需）
sudo mount /dev/sda1 /mnt/data           # 手动挂载
sudo umount /mnt/data                    # 卸载
```

**开机自动挂载**：编辑 `/etc/fstab`

```bash
# 先拿到 UUID
sudo blkid
# 追加一行（重要：必须用 UUID，不要用 /dev/sda1，设备名会变）
UUID=xxxx-xxxx  /mnt/data  ext4  defaults,noatime  0  2
```

验证不重启是否生效：

```bash
sudo mount -a        # 有报错立刻能发现
```

### 9.4 WSL 特有：磁盘空间与自动清理

WSL 的虚拟磁盘（ext4.vhdx）只会变大不会自动缩小，是很多人踩的坑。

```bash
# 在 Ubuntu 里清理空间
sudo apt clean
sudo apt autoremove
rm -rf /var/lib/apt/lists/*
sudo truncate -s 0 /var/log/syslog

# 关闭 WSL 后在 PowerShell 里压缩（真正释放 Windows 磁盘空间）
# wsl --shutdown
# 然后在管理员 PowerShell：
# Optimize-VHD -Path "路径\ext4.vhdx" -Mode Full
```

---

## 10. 文本处理三剑客

### 10.1 grep（搜索）

```bash
grep "error" app.log                     # 基本搜索
grep -i "error" app.log                  # 忽略大小写
grep -n "error" app.log                  # 显示行号
grep -r "api_backend" /etc/nginx/       # 递归搜索目录
grep -c "error" app.log                  # 只输出匹配行数（统计用）
grep -v "debug" app.log                  # 反向：排除包含 debug 的行
grep -E "error|warn" app.log             # 扩展正则
grep -rn --include="*.conf" "upstream" /etc/nginx/   # 只搜特定文件类型
grep -A3 -B3 "error" app.log             # 显示上下各3行（-A后 -B前）
grep -o "192.168.*" access.log           # 只输出匹配到的部分
```

### 10.2 sed（流编辑器）

```bash
sed -n '1,10p' file.txt                  # 打印1-10行
sed -n '5p' file.txt                     # 打印第5行
sed 's/old/new/g' file.txt               # 替换（默认只第一行）
sed 's/old/new/g' file.txt > out.txt     # 替换全部，输出到新文件
sed -i 's/3001/4001/g' nginx.conf        # -i 直接改文件（危险，先备份！）
sed -i.bak 's/a/b/g' file.txt            # 改的同时留 .bak 备份（推荐）
sed '/comment/d' file.txt                # 删除包含 comment 的行
sed '/^$/d' file.txt                     # 删除空行
sed -n '/start/,/end/p' file.txt         # 打印 start 到 end 之间的行
sed '1i\新的一行' file.txt               # 在第1行前插入
sed '$a\最后一行' file.txt                # 在末尾追加
```

### 10.3 awk（按列处理）

```bash
awk '{print $1}' file.txt                # 第1列
awk '{print $1, $3}' file.txt            # 第1和第3列
awk -F',' '{print $2}' data.csv          # 指定分隔符
awk -F'\t' '{print $1}' file.txt         # tab 分隔
awk -F':' '{print $1}' /etc/passwd       # 常用：提取用户名
awk '{sum += $1} END {print sum}' nums   # 求和
awk 'NR>1 {print $1}' file.txt           # 跳过表头
awk -F',' 'NR>1 {sum+=$3} END {print sum/NR}' data.csv   # 算平均值
awk '{print NR": "$0}' file.txt          # 显示行号
awk '/error/ {print}' app.log            # 条件过滤
awk 'NR==5 {print; exit}' file.txt       # 只处理第5行然后退出
```

### 10.4 管道与重定向（真正的威力所在）

```bash
command1 | command2                      # 管道：左边输出当右边输入
command > file                           # 覆盖写入（危险，会清空原文件）
command >> file                          # 追加写入
command 2>&1 | tee -a log.txt            # 屏幕上看到，同时存文件
command < input.txt                      # 从文件读入
command &> file                          # stdout + stderr 都进文件

# 实战组合
ps aux | grep node | grep -v grep       # 找进程且排除grep 自己
ss -tlnp | grep 80                       # 找80端口占用
cat access.log | grep "404" | wc -l      # 统计404的请求数
du -h --max-depth=1 /var | sort -rh | head -10    # 找最大目录
journalctl -u nginx -n 1000 | grep -i error | tail -20    # 近期错误汇总
```

> 记住这个技巧：**`[n]ode` 而不是 `node`**  
> `grep node` 会匹配到 `grep node` 这个命令本身，`grep [n]ode` 用正则字符类  
> 让模式匹配 "node" 但命令行文本是 "[n]ode"，从而避开自我匹配。

---

## 11. 压缩与解压

```bash
# tar.gz（最常见）
tar -czvf archive.tar.gz dir/           # c=创建 z=gzip v=详细 f=文件
tar -xzvf archive.tar.gz                # x=解压
tar -xzf archive.tar.gz -C /opt/         # 解压到指定目录
tar -tzf archive.tar.gz                  # 只查看内容不解压

# 只打包不压缩（更快）
tar -cf archive.tar dir/

# 排除某些文件
tar --exclude='*.log' --exclude='node_modules' -czf archive.tar.gz dir/

# 查看包大小
tar -czvf archive.tar.gz dir/ | wc -c

# zip 格式
sudo apt install zip unzip
zip -r archive.zip dir/
unzip archive.zip
unzip -l archive.zip                    # 只列表

# 解压 .zip 到指定目录
unzip archive.zip -d /opt/app/

# 批量解压
for f in *.tar.gz; do tar -xzf "$f"; done
```


**WSL 特别有用**：把 Windows 文件打包给 Linux 用。

```bash
# 在 Ubuntu 里访问 Windows 文件
cd /mnt/c/Users/yuxiangming/Downloads
ls
# 性能提示：/mnt/c 是 9p 协议，跨系统读写很慢。
# 生产项目建议复制到 Linux 文件系统内部：
cp -a /mnt/c/Users/yuxiangming/project ~/project
```

---

## 12. 软件包管理 apt

```bash
sudo apt update                # 更新软件源列表（装包前必做）
sudo apt upgrade               # 升级已安装的包
sudo apt install nginx         # 安装
sudo apt remove nginx          # 卸载
sudo apt autoremove            # 清理不再需要的依赖
sudo apt purge nginx           # 卸载并删除配置文件
sudo apt install -y nginx      # -y 自动确认yes，不交互
sudo apt search nginx          # 搜索软件包
apt show nginx                 # 查看包的详细信息
apt list --installed | grep nginx
dpkg -l                        # 已安装的所有包
dpkg -L nginx                  # 某个包安装了哪些文件
dpkg -S /usr/sbin/nginx        # 反查：某文件属于哪个包
```

**apt update 和 apt upgrade 的区别**：

- `apt update` 只是刷新"有哪些新版本"的清单，不动你的系统
- `apt upgrade` 才是真的升级

**推荐安全习惯**：

```bash
sudo apt update && sudo apt upgrade && sudo apt autoremove
```

## 14. 本项目实战演练

> 目标：在 WSL Ubuntu 里跑起 Nginx + 两个 Node 后端，验证负载均衡。  
> 这套命令跟着前面章节走，每一步都有对应的知识点。

### 14.1 准备环境

```bash
# 1. 检查系统版本和内核
lsb_release -a && uname -r

# 2. 更新系统
sudo apt update && sudo apt upgrade -y

# 3. 安装 Node.js（用 nvm 更灵活）
sudo apt install -y curl
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/master/install.sh | bash
source ~/.bashrc
nvm install 22
nvm use 22
node -v && npm -v

# 4. 安装 Nginx（不要用 Windows 目录里那个 nginx.exe）
sudo apt install -y nginx
nginx -v
```

### 14.2 拷贝项目到 Linux 文件系统

```bash
# 重要：不要在 /mnt/c 下跑 Node 项目，跨系统 IO 极慢
mkdir -p ~/nginx-project
cp -a /mnt/i/练习/nginx/backend ~/nginx-project/
cp -a /mnt/i/练习/nginx/frontend ~/nginx-project/

ls -la ~/nginx-project/
# 确认权限
chmod +x ~/*.sh 2>/dev/null
```

### 14.3 先用前台方式验证能跑

```bash
cd ~/nginx-project
node backend/api-server1.js
# 另开一个终端
node backend/api-server2.js
# 再开一个
curl -s http://127.0.0.1:4001/api/user
curl -s http://127.0.0.1:4002/api/user
```

两个都返回 JSON，说明后端没问题。`Ctrl+C` 停掉。

### 14.4 配置 Ubuntu 版 Nginx

Windows 那份 `nginx.conf` 里 `root I:/练习/nginx/frontend;` 是 Windows 路径，  
在 Linux 里必须改成 Linux 路径。

```bash
sudo cp /etc/nginx/sites-available/default /etc/nginx/sites-available/nginx-app
sudo nano /etc/nginx/sites-available/nginx-app
```

写入内容：

```nginx
server {
    listen 80;
    listen [::]:80;
    server_name localhost;

    # 前端静态文件
    location / {
        root /home/你的用户名/nginx-project/frontend;
        index index.html;
        try_files $uri $uri/ /index.html;
    }

    # 后端 API 负载均衡
    location /api/ {
        proxy_pass http://api_backend;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    # 静态资源缓存
    location ~* \.(css|js|png|jpg|jpeg|gif|ico|svg|woff2?)$ {
        root /home/你的用户名/nginx-project/frontend;
        expires 30d;
        add_header Cache-Control "public, no-transform";
    }
}
```

在 `http {}` 块里加 upstream（Ubuntu 默认在 `/etc/nginx/nginx.conf` 的 http 块内）：

```nginx
upstream api_backend {
    server 127.0.0.1:4001;
    server 127.0.0.1:4002;
}
```

**启用并测试**：

```bash
sudo ln -sf /etc/nginx/sites-available/nginx-app /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default    # 移除默认站点避免冲突

sudo nginx -t                               # 测试语法（改完必做）
sudo systemctl reload nginx
systemctl status nginx
```

> **关键**：`sudo nginx -t` 语法检查必须成为肌肉记忆。  
> 写错了不检查直接 reload，会把现有服务搞挂。

### 14.5 用 systemd 管理两个后端

```bash
# 为 server1 创建服务
sudo tee /etc/systemd/system/api-server1.service > /dev/null << 'EOF'
[Unit]
Description=Backend API Server 1
After=network.target

[Service]
Type=simple
User=你的用户名
WorkingDirectory=/home/你的用户名/nginx-project/backend
ExecStart=/usr/bin/node api-server1.js
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# 为 server2 创建服务（复制一份改端口）
sudo tee /etc/systemd/system/api-server2.service > /dev/null << 'EOF'
[Unit]
Description=Backend API Server 2
After=network.target

[Service]
Type=simple
User=你的用户名
WorkingDirectory=/home/你的用户名/nginx-project/backend
ExecStart=/usr/bin/node api-server2.js
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
```

**激活并启动**：

```bash
sudo systemctl daemon-reload
sudo systemctl enable api-server1 api-server2    # 开机自启
sudo systemctl start api-server1 api-server2

# 检查状态
systemctl status api-server1 api-server2
# 实时看日志（排查神器）
journalctl -u api-server1 -f
```

**验证端口真的起来了**：

```bash
ss -tlnp | grep -E '4001|4002|80'
# 应该看到三行：4001(node) 4002(node) 80(nginx)
```

### 14.6 验证负载均衡

```bash
# 方式1：命令行连续请求（最准确）
for i in $(seq 1 10); do
    curl -s http://localhost/api/user | grep -o '"server":"[^"]*"'
done

# 预期输出 服务器A 服务器B 交替出现

# 方式2：统计比例
for i in $(seq 1 20); do curl -s http://localhost/api/user; echo; done \
  | grep -o '服务器[AB]' | sort | uniq -c

# 方式3：浏览器打开
# Windows 浏览器访问 http://localhost
# 但浏览器 keep-alive 会导致都落同一台，用无痕窗口测试更准
```

### 14.7 练习负载均衡策略

```bash
sudo nano /etc/nginx/sites-available/nginx-app
# 在 upstream 里改策略，然后：
sudo nginx -t && sudo systemctl reload nginx
```

| 策略    | 配置                                | 预期效果       |
| ----- | --------------------------------- | ---------- |
| 加权轮询  | `server 127.0.0.1:4001 weight=3;` | 3:1 分配     |
| IP 哈希 | 加 `ip_hash;`                      | 同一 IP 固定一台 |
| 最少连接  | 加 `least_conn;`                   | 按连接数分配     |

**模拟后端宕机**：

```bash
sudo systemctl stop api-server2
for i in $(seq 1 6); do curl -s http://localhost/api/user | grep -o '"server":"[^"]*"'; done
# 全部是服务器A
sudo systemctl start api-server2    # 恢复
```

### 14.8 WSL 开机自启完整配置

```bash
# 1. 启用 systemd（需要 Windows 侧配置）
# 编辑 Windows 的 %UserProfile%\.wslconfig：
#   [wsl2]
#   systemd=true
# 然后在 PowerShell: wsl --shutdown

# 2. 验证 systemd 是否启用
ps -p 1 -o comm=
# 输出 systemd 说明启用成功；否则是 init/sh

# 3. 服务已 enable 后就随 WSL 启动自动运行
systemctl list-unit-files | grep -E 'enabled' | head
```

> 重要：WSL **不是**真正的开机自启。Windows 不启动 WSL，WSL 内的服务就不会跑。  
> 需要在 Windows 侧用任务计划程序挂一个开机任务执行 `wsl.exe -d Ubuntu`。

---

## 15. 故障排查决策树

### 服务访问不通

```
1. 进程在吗？
   pgrep -a node  →  没有？启动它

2. 端口在监听吗？
   ss -tlnp | grep 4001  →  没有？进程崩了，看 journalctl -u 服务名 -n 50

3. 本机能连吗？
   curl -s http://127.0.0.1:4001/api/user  →  连不上？后端有问题

4. Nginx 配置对吗？
   sudo nginx -t  →  语法错误？看报错行号
   cat /etc/nginx/sites-enabled/  →  软链接建了吗

5. Nginx 转发出去了吗？
   sudo tail -f /var/log/nginx/error.log  →  看有没有 "connect() failed"

6. 防火墙挡了吗？
   sudo ufw status  →  needed 的端口放行：sudo ufw allow 80/tcp

7. SELinux（CentOS 系才有，Ubuntu 没有）
   Ubuntu 不需要考虑这一层
```

### 磁盘满了

```bash
df -h                              # 哪个分区满了
du -h --max-depth=1 / | sort -rh | head -20    # 定位大目录
sudo du -h --max-depth=1 /var | sort -rh | head
# 常见清理顺序
sudo journalctl --vacuum-size=100M  # 日志
sudo apt clean && sudo apt autoremove  # apt 缓存
docker system prune -a               # docker（如果装了）
find /tmp -type f -mtime +30 -delete  # 临时文件
```

### 内存不足

```bash
free -h                             # available 还剩多少
ps aux --sort=-%mem | head -10     # 谁在吃
# 常见元凶：内存泄漏的进程、配置了过大的缓存、
#          zswap/zram 没开、WSL 的 .wslconfig 里内存上限太小
```

### 性能问题定位

```bash
# Linux 生产环境标准三件套（都来自 sysstat 包）
sudo apt install sysstat
iostat -x 1        # 磁盘 IO，重点看 %util 和 await
vmstat 1           # 上下文切换、CPU 等待
mpstat -P ALL 1    # 每个 CPU 核的使用率

# 通用组合拳
top 按 1           # 显示每个 CPU 核
top 按 M           # 按内存排序
top 按 1           # 再按一次看每个核
```

---

## 16. 速查表

### 系统信息

| 命令               | 作用        |
| ---------------- | --------- |
| `lsb_release -a` | Ubuntu 版本 |
| `uname -r`       | 内核版本      |
| `uptime`         | 负载均值      |
| `nproc`          | CPU 核数    |
| `free -h`        | 内存使用      |
| `df -h`          | 磁盘使用      |

### 文件

| 命令                 | 作用        |
| ------------------ | --------- |
| `ls -lah`          | 详细列出含隐藏文件 |
| `cd -`             | 回到上一个目录   |
| `cp -a src dst`    | 复制并保留属性   |
| `mv a b`           | 移动/重命名    |
| `find / -name "x"` | 按名查找      |
| `tail -f log`      | 实时跟踪日志    |
| `less`             | 分页查看      |
| `du -sh dir`       | 目录大小      |

### 权限

| 命令                        | 作用         |
| ------------------------- | ---------- |
| `chmod 644 f`             | 标准文件权限     |
| `chmod 755 script.sh`     | 脚本权限       |
| `chown -R user:group dir` | 改所有者       |
| `sudo`                    | 单条命令提权     |
| `sudo -i`                 | 切到 root 环境 |

### 进程

| 命令              | 作用     |
| --------------- | ------ |
| `ps aux`        | 所有进程   |
| `top`           | 实时监控   |
| `pgrep -a name` | 按名字找进程 |
| `kill PID`      | 优雅停止   |
| `kill -9 PID`   | 强制杀    |
| `nohup cmd &`   | 后台常驻   |
| `tmux new -s x` | 可交互的会话 |

### 网络

| 命令                | 作用      |
| ----------------- | ------- |
| `ip a`            | IP 地址   |
| `ss -tulnp`       | 监听端口+进程 |
| `curl -I url`     | 只看响应头   |
| `dig domain`      | DNS 查询  |
| `ping -c 4 host`  | 连通测试    |
| `traceroute host` | 路由路径    |

### 服务

| 命令                        | 作用     |
| ------------------------- | ------ |
| `systemctl status x`      | 服务状态   |
| `sudo systemctl reload x` | 重载配置   |
| `systemctl enable x`      | 开机自启   |
| `journalctl -u x -f`      | 实时日志   |
| `sudo nginx -t`           | 配置语法检查 |

### 文本

| 命令                       | 作用      |
| ------------------------ | ------- |
| `grep -rn "x" dir`       | 递归搜索    |
| `grep -c "x" f`          | 统计行数    |
| `sed 's/a/b/g' f`        | 替换      |
| `awk '{print $1}' f`     | 取列      |
| `cmd \| grep x \| wc -l` | 管道组合    |
| `tee -a log`             | 屏幕+文件双写 |

---

## 17. 命令全称与参数拆解

下面汇总本教程中出现的命令名称、可靠的英文展开和常见选项。很多命令本来就是普通英文词或历史命名，并不是每个字母都对应一个单词；这类命令会注明“普通词”或只解释用途，不强行编造词源。

### 17.1 系统与文件命令

| 命令              | 英文全称或记忆方式                                     | 命令作用                                        |
| --------------- | --------------------------------------------- | ------------------------------------------- |
| `uname`         | Unix name                                     | 显示系统名称和内核等信息；`-a` 是 all，显示全部可用信息            |
| `hostname`      | host name                                     | 显示或设置主机名                                    |
| `lsb_release`   | Linux Standard Base release                   | 显示 Linux 发行版信息；`-a` 是 all                   |
| `cat`           | concatenate                                   | 连接并输出文件内容；查看单个文件时也常用来直接显示内容                 |
| `uptime`        | up time                                       | 显示系统已运行时间和负载均值                              |
| `date`          | 普通英文词“日期”                                     | 显示或设置日期时间                                   |
| `timedatectl`   | time and date control                         | 查看或控制系统时间、日期及时区                             |
| `whoami`        | who am I                                      | 显示当前用户名                                     |
| `id`            | identity 的记忆方式                                | 显示用户 ID 和组 ID                               |
| `lscpu`         | list CPU                                      | 显示 CPU 架构信息                                 |
| `nproc`         | number of processing units                    | 显示可用处理单元数量，通常指逻辑 CPU 数                      |
| `free`          | 普通英文词“空闲”                                     | 显示内存使用情况                                    |
| `lsblk`         | list block devices                            | 列出块设备，例如磁盘和分区                               |
| `lspci`         | list PCI                                      | 列出 PCI 设备                                   |
| `lsusb`         | list USB                                      | 列出 USB 设备                                   |
| `dmidecode`     | DMI decode；DMI = Desktop Management Interface | 解码并显示硬件管理信息                                 |
| `pwd`           | print working directory                       | 显示当前工作目录                                    |
| `cd`            | change directory                              | 切换目录                                        |
| `ls`            | list                                          | 列出目录内容                                      |
| `touch`         | 普通英文词“触碰”                                     | 创建空文件，或更新文件时间戳                              |
| `mkdir`         | make directory                                | 创建目录；`-p` 创建缺失的父目录                          |
| `cp`            | copy                                          | 复制文件或目录；`-r` 递归复制，`-a` archive（归档复制，尽量保留属性） |
| `mv`            | move                                          | 移动或重命名文件                                    |
| `rm`            | remove                                        | 删除文件；`-r` 递归删除目录                            |
| `rmdir`         | remove directory                              | 删除空目录                                       |
| `ln`            | link                                          | 创建链接；`-s` 创建符号链接，`-f` 覆盖已有目标链接              |
| `find`          | 普通英文词“查找”                                     | 按条件查找文件和目录                                  |
| `mktemp`        | make temporary                                | 创建临时文件或目录；`-d` 创建临时目录                       |
| `less`          | 比 `more` 少（历史上的文字游戏）                          | 分页查看文件内容                                    |
| `head` / `tail` | 普通英文词“头部/尾部”                                  | 显示文件开头/结尾；`-n` 指定行数，`-f` 跟踪追加内容             |
| `wc`            | word count                                    | 统计行数、单词数或字节数；`-l` 只统计行数                     |
| `echo`          | 普通英文词“回显”                                     | 输出文本或变量值                                    |
| `nano`          | GNU nano 文本编辑器名称；不是命令选项缩写                     | 在终端中编辑文本文件                                  |
| `trash-put`     | trash-cli 提供的命令                               | 将文件移入回收站，而不是直接删除                            |


### 17.2 权限、用户与进程命令

| 命令          | 英文全称或记忆方式                                      | 命令作用                                                       |
| ----------- | ---------------------------------------------- | ---------------------------------------------------------- |
| `chmod`     | change mode                                    | 修改文件权限模式；`u` 所有者、`g` 组、`o` 其他人、`a` 全部，`+` 添加、`-` 移除、`=` 设置 |
| `chown`     | change owner                                   | 修改文件所有者；`user:group` 同时指定用户和组                              |
| `umask`     | user file-creation mode mask                   | 设置新建文件和目录权限的屏蔽掩码                                           |
| `sudo`      | 常见记忆法是“superuser do”；也有“substitute user do”的解释 | 以其他用户（通常是 root）执行命令                                        |
| `su`        | substitute user                                | 切换到其他用户；`-` 使用目标用户的登录环境                                    |
| `adduser`   | add user                                       | 添加用户                                                       |
| `passwd`    | password                                       | 设置或修改用户密码                                                  |
| `usermod`   | user modify                                    | 修改用户账户；`-aG` 将组追加到附加组列表，`-s` 设置登录 shell                    |
| `userdel`   | user delete                                    | 删除用户；`-r` 同时删除家目录和邮件目录                                     |
| `groupadd`  | group add                                      | 创建用户组                                                      |
| `groupdel`  | group delete                                   | 删除用户组；仅删除已无成员或依赖的练习组                                       |
| `groups`    | 普通英文词“组”                                       | 显示当前用户或指定用户所属的组                                            |
| `ps`        | process status                                 | 显示进程状态；`aux` 是常见 BSD 风格组合，`-ef` 是另一种全进程格式                  |
| `pgrep`     | process grep                                   | 按名称或条件查找进程；`-a` 同时显示完整命令行                                  |
| `pstree`    | process tree                                   | 以树形显示进程关系；`-p` 显示进程 ID                                     |
| `top`       | 普通名称，可记作查看资源占用排在前面的进程                          | 实时查看进程和系统资源                                                |
| `htop`      | 交互式进程查看器名称，不按字母拆解                              | 以 `top` 为基础提供更方便的交互式查看界面                                   |
| `kill`      | 普通英文词“发送信号/终止”                                 | 向进程发送信号；`-TERM` 请求优雅退出，`-9` 发送 SIGKILL 强制终止                |
| `killall`   | kill all                                       | 按进程名称向匹配进程发送信号                                             |
| `pkill`     | process kill                                   | 按名称或条件向进程发送信号；`-f` 匹配完整命令行                                 |
| `jobs`      | 普通英文词“任务”                                      | 列出当前 shell 的后台和挂起任务                                        |
| `fg` / `bg` | foreground / background                        | 将任务切到前台/后台运行                                               |
| `nohup`     | no hangup                                      | 忽略挂断信号，让命令在终端退出后继续运行                                       |
| `tmux`      | terminal multiplexer                           | 终端复用器；可在一个终端中管理多个会话和窗口                                     |
| `node`      | Node.js 运行时命令                                  | 执行 JavaScript 程序；`-v` 显示版本                                 |
| `npm`       | Node Package Manager                           | Node.js 包管理器；`-v` 显示版本                                     |
| `nvm`       | Node Version Manager                           | Node.js 版本管理器                                              |

### 17.3 网络、服务、日志与磁盘命令

| 命令                 | 英文全称或记忆方式                      | 命令作用                                                                                                          |
| ------------------ | ------------------------------ | ------------------------------------------------------------------------------------------------------------- |
| `ip`               | Internet Protocol              | 查看或配置网络接口、地址和路由；`a` 是 `address` 的简写                                                                           |
| `ss`               | socket statistics              | 查看 socket 和网络连接状态                                                                                             |
| `lsof`             | list open files                | 列出打开的文件；Linux 中网络连接也表现为文件描述符                                                                                  |
| `fuser`            | file user                      | 查找正在使用指定文件或文件系统的进程                                                                                            |
| `ping`             | 名称来自声纳回声的拟声；不是可靠的首字母缩写         | 通过 ICMP 回显测试连通性；`-c` 指定发送次数                                                                                   |
| `traceroute`       | trace route                    | 追踪到目标的网络路由路径                                                                                                  |
| `mtr`              | My Traceroute                  | 结合路由追踪和持续探测的网络诊断工具                                                                                            |
| `dig`              | domain information groper      | 查询 DNS 信息；`+short` 缩短输出                                                                                       |
| `nslookup`         | name server lookup             | 查询 DNS 名称或记录                                                                                                  |
| `curl`             | client URL（cURL 项目的常用展开）       | 通过 URL 传输数据；`-I` 取响应头，`-X` 指定方法，`-d` 提交数据，`-H` 设置请求头，`-o` 指定输出文件，`-O` 使用远端文件名，`-s` 静默输出                       |
| `telnet`           | teletype network               | 传统远程终端协议/客户端，也可用于简单端口连通测试                                                                                     |
| `nc`               | netcat                         | 网络连接工具；`-z` 扫描端口不发送数据，`-v` 显示详细信息                                                                             |
| `systemd`          | system and service manager 的名称 | Linux 的系统和服务管理套件                                                                                              |
| `systemctl`        | systemd control                | 管理 systemd 服务和单元；`start` 启动，`stop` 停止，`restart` 重启，`reload` 重载，`status` 查看状态，`enable` 设置开机启动，`disable` 取消开机启动 |
| `journalctl`       | journal control                | 查询 systemd 日志；`-u` 指定单元，`-f` 跟踪，`-n` 指定行数，`-b` 限定本次启动，`-p` 指定优先级                                              |
| `nginx`            | 名称源自 engine-x 的读音              | Web 服务器和反向代理；`-t` 检查配置，`-v` 显示版本，`-s` 向主进程发送信号                                                                |
| `logrotate`        | log rotate                     | 轮转、压缩和清理日志文件；`-d` 仅调试演练，`-f` 强制轮转                                                                             |
| `dmesg`            | diagnostic message 的记忆方式       | 显示内核环形缓冲区中的消息                                                                                                 |
| `df`               | disk free                      | 显示文件系统磁盘空间；`-h` 使用易读单位，`-i` 显示 inode                                                                          |
| `du`               | disk usage                     | 统计文件或目录占用空间；`-s` 汇总，`-h` 使用易读单位                                                                               |
| `mount` / `umount` | mount / unmount                | 挂载/卸载文件系统；`umount` 的拼写沿用 Unix 命名                                                                              |
| `fdisk`            | fixed disk                     | 查看或管理磁盘分区表；`-l` 列出分区                                                                                          |
| `blkid`            | block device ID                | 显示块设备的文件系统类型和 UUID 等标识                                                                                        |
| `ufw`              | Uncomplicated Firewall         | Ubuntu 常用的简化防火墙管理命令                                                                                           |
| `truncate`         | 普通英文词“截断”                      | 改变文件大小；`-s 0` 将文件清空但保留文件本身                                                                                    |
| `docker`           | Docker 容器平台命令                  | 管理容器和镜像；`system prune` 清理未使用资源，`-a` 扩大清理范围                                                                    |
| `iostat`           | input/output statistics        | 显示 CPU 和磁盘输入/输出统计，通常由 `sysstat` 软件包提供                                                                         |
| `vmstat`           | virtual memory statistics      | 显示进程、内存、交换区和 CPU 等统计，通常由 `procps` 提供                                                                          |
| `mpstat`           | multiprocessor statistics      | 显示处理器使用统计，通常由 `sysstat` 软件包提供                                                                                 |
| `wsl` / `wsl.exe`  | Windows Subsystem for Linux    | 从 Windows 管理或启动 Linux 发行版；`--shutdown` 关闭所有运行中的 WSL 实例                                                        |
| `Optimize-VHD`     | Optimize Virtual Hard Disk     | Hyper-V PowerShell 命令，用于优化虚拟硬盘；需相应 Windows 模块和权限                                                              |
| `Get-Command`      | PowerShell 获取命令信息              | 查询 PowerShell 命令或 cmdlet 是否可用                                                                                 |

### 17.4 文本、归档、软件包与 Shell 命令

| 命令                  | 英文全称或记忆方式                                  | 命令作用                                                                                              |
| ------------------- | ------------------------------------------ | ------------------------------------------------------------------------------------------------- |
| `grep`              | global regular expression print（源自早期编辑器命令） | 按文本模式搜索行；`-i` 忽略大小写，`-n` 行号，`-r` 递归，`-c` 计数，`-v` 反选，`-E` 扩展正则，`-A`/`-B` 显示匹配行之后/之前的行，`-o` 只输出匹配部分 |
| `sed`               | stream editor                              | 流式编辑文本；`-n` 关闭默认输出，`-i` 原地修改，`s` 替换，`g` 每行全局替换，`p` 打印，`d` 删除                                      |
| `awk`               | 由作者 Aho、Weinberger、Kernighan 姓氏首字母组成       | 按记录和字段处理文本；`-F` 指定字段分隔符，`NR` 当前记录号，`$1` 第一字段，`$0` 整行，`END` 所有输入处理完后执行                             |
| `sort`              | 普通英文词“排序”                                  | 排序文本；`-r` 反向，`-h` 按易读数值排序                                                                         |
| `uniq`              | unique                                     | 合并或统计相邻重复行；常与 `sort` 连用                                                                           |
| `xargs`             | 从标准输入构造并执行参数                               | 将输入内容转成后续命令的参数；`-0` 处理 NUL 分隔输入，`-n` 限制每次参数数量，`-I` 指定替换字符串                                        |
| `tee`               | 以字母 T 形象记忆分流                               | 将输入同时写到屏幕和文件；`-a` 追加到文件                                                                           |
| `tar`               | tape archive                               | 打包归档；`-c` 创建，`-x` 解包，`-t` 列表，`-z` 通过 gzip 压缩，`-v` 显示过程，`-f` 指定归档文件，`-C` 指定目录                      |
| `gzip`              | GNU zip                                    | gzip 压缩工具；`.gz` 是常见压缩文件后缀                                                                         |
| `zip` / `unzip`     | 普通名称“压缩包/解压”                               | 创建/解开 ZIP 格式压缩包；`-r` 递归处理，`-l` 列表，`-d` 指定解压目录                                                     |
| `apt`               | Advanced Package Tool                      | Debian/Ubuntu 高级软件包管理工具                                                                           |
| `dpkg`              | Debian package                             | Debian 软件包底层管理工具；`-l` 列表，`-L` 查看包安装文件，`-S` 查询文件所属包                                                |
| `seq`               | sequence                                   | 输出数字序列                                                                                            |
| `sleep`             | 普通英文词“睡眠”                                  | 等待指定时间                                                                                            |
| `wait`              | 普通英文词“等待”                                  | 等待当前 shell 的后台任务结束并取得退出状态                                                                         |
| `printf`            | print formatted                            | 按格式输出文本；可用于构造稳定的练习输入                                                                              |
| `env`               | environment                                | 查看或在指定环境中运行命令                                                                                     |
| `export` / `unset`  | 普通英文词“导出/取消”                               | 设置导出给子进程的环境变量/移除变量                                                                                |
| `alias` / `unalias` | alias / remove alias                       | 创建/删除 shell 命令别名                                                                                  |
| `history`           | 普通英文词“历史记录”                                | 查看 shell 命令历史                                                                                     |
| `source`            | 普通英文词“来源”                                  | 在当前 shell 读取并执行文件内容；`.` 是它的常用简写                                                                   |
| `command`           | 普通英文词“命令”                                  | shell 内建工具；可检查或执行命令，`-v` 用于查询命令是否可用                                                               |
| `test` / `[`        | 条件测试命令                                     | 检查文件、字符串或数字条件；`[` 写法末尾需要对应的 `]`                                                                   |
| `man`               | manual                                     | 查看命令手册页；例如 `man ls`                                                                               |
| `bash`              | Bourne Again SHell                         | 常见 Linux 命令解释器；`.bashrc` 是 Bash 交互式 shell 配置文件                                                    |
| `sysstat`           | system statistics 工具集                      | 提供 `iostat`、`mpstat` 等性能统计工具的软件包                                                                  |


### 17.5 常见选项、缩写和符号

选项含义要结合具体命令看，同一个字母可能有不同意思。下面列出本教程里常见的用法：

| 写法              | 英文展开或含义                                | 例子                                               |   |               |
| --------------- | -------------------------------------- | ------------------------------------------------ | - | ------------- |
| `-a`            | all（全部）、append（追加）或 archive（归档），依命令而定  | `ls -a` 显示隐藏文件；`tee -a` 追加写入；`cp -a` 归档复制        |   |               |
| `-l`            | long（长格式）、list（列出）或 lines（行数），依命令而定    | `ls -l` 长格式；`dpkg -l` 列表；`wc -l` 统计行数            |   |               |
| `-h`            | human-readable（易读单位），有些命令中也表示 help     | `df -h`、`du -h` 显示易读容量；具体以命令帮助为准                 |   |               |
| `-r` / `-R`     | recursive（递归）或 reverse（反向），大小写和命令会改变含义 | `cp -r` 递归复制；`sort -r` 反向排序；`chmod -R` 递归改权限     |   |               |
| `-f`            | file（文件）、follow（跟踪）、force（强制）等，依命令而定   | `tar -f` 指定归档文件；`tail -f` 跟踪；`logrotate -f` 强制轮转 |   |               |
| `-v`            | verbose（详细输出）                          | `tar -v`、`nc -v` 显示更多过程信息                        |   |               |
| `-n`            | number（数量/行号）或 no（关闭某行为），依命令而定         | `head -n` 指定行数；`grep -n` 显示行号；`sed -n` 关闭默认打印    |   |               |
| `-i`            | ignore case（忽略大小写）或 in-place（原地修改）     | `grep -i` 忽略大小写；`sed -i` 原地修改                    |   |               |
| `-p`            | parents（父目录）、port（端口）、process ID（进程号）等 | `mkdir -p` 创建父目录；`ss` 过滤端口；`pstree -p` 显示 PID    |   |               |
| `-s`            | summary（汇总）、silent（静默）、signal（信号）等     | `du -s` 汇总；`curl -s` 静默；`nginx -s` 发送信号          |   |               |
| `-x`            | extract（解包）、execute（执行）或其他命令专用含义       | `tar -x` 解包；不要脱离具体命令单独记忆                         |   |               |
| `--`            | 长选项前缀                                  | `--since`、`--include`、`--max-depth`              |   |               |
| `2>&1`          | 将文件描述符 2（标准错误）重定向到文件描述符 1（标准输出）当前指向的位置 | `command > app.log 2>&1`                         |   |               |
| `>` / `>>`      | 重定向标准输出并覆盖/追加文件                        | `command > file` 覆盖；`command >> file` 追加         |   |               |
| `<`             | 从文件重定向标准输入                             | `command < input.txt`                            |   |               |
| `\|`            | pipe（管道）                               | 将左侧命令的标准输出传给右侧命令                                 |   |               |
| `&&` / `\|\|`   | AND / OR 条件执行                          | `a && b`：a 成功才执行 b；\`a                           |   | b\`：a 失败才执行 b |
| `&`             | 将命令放到后台；在 `2>&1` 中则是文件描述符重定向语法的一部分     | `command &` 后台运行                                 |   |               |
| `$变量` / `$(命令)` | 展开变量/命令替换                              | `$HOME` 取变量；`$(hostname -I)` 取命令输出               |   |               |

记忆时先抓“动作”：`list` 列出、`copy` 复制、`move` 移动、`remove` 删除、`change` 修改、`show/print` 显示、`find/search` 查找。再把参数当作范围或格式，例如 `-r` 递归、`-h` 易读格式、`-n` 指定数量。遇到选项含义不确定时，用 `命令 --help` 或 `man 命令` 核对，不要仅凭字母猜测。



### 17.6 每条命令动手练

下面按 17.1 到 17.4 的顺序，给每个命令条目一个具体例子。普通练习优先使用只读查询或临时目录；账户实验会改动系统用户和组，仅在可丢弃的测试环境中执行，并按步骤清理。请在同一个 Bash 终端按顺序练习前两个小节，这样变量和临时文件会保留。标注“可选/需安装”的命令在系统没有相应工具时可以先跳过。

#### 系统与文件

先创建练习目录和样例文件：

```bash
practice_dir=$(mktemp -d)
printf 'alpha\nbeta\ngamma\n' > "$practice_dir/sample.txt"
```

| 命令 | 练习实例 |
|---|---|
| `uname` | `uname -a` |
| `hostname` | `hostname` |
| `lsb_release` | `lsb_release -a` |
| `cat` | `cat /etc/os-release` |
| `uptime` | `uptime` |
| `date` | `date` |
| `timedatectl` | `timedatectl status` |
| `whoami` | `whoami` |
| `id` | `id` |
| `lscpu` | `lscpu` |
| `nproc` | `nproc` |
| `free` | `free -h` |
| `lsblk` | `lsblk` |
| `lspci` | `lspci \| head` |
| `lsusb` | `lsusb` |
| `dmidecode` | 可选，需 sudo：`sudo dmidecode -t system` |
| `pwd` | `pwd` |
| `cd` | `cd "$practice_dir"`，然后用 `pwd` 确认位置 |
| `ls` | `ls -lah "$practice_dir"` |
| `touch` | `touch "$practice_dir/empty.txt"` |
| `mkdir` | `mkdir -p "$practice_dir/a/b"` |
| `cp` | `cp -a "$practice_dir/sample.txt" "$practice_dir/copy.txt"` |
| `mv` | `mv "$practice_dir/copy.txt" "$practice_dir/renamed.txt"` |
| `rm` | `rm "$practice_dir/empty.txt"`，只删除刚创建的练习文件 |
| `rmdir` | `mkdir "$practice_dir/empty-dir"; rmdir "$practice_dir/empty-dir"` |
| `ln` | `ln -s "$practice_dir/sample.txt" "$practice_dir/sample-link"` |
| `find` | `find "$practice_dir" -maxdepth 3 -type f` |
| `less` | `less /etc/os-release`，按 `q` 退出 |
| `head` / `tail` | `head -n 2 "$practice_dir/sample.txt"; tail -n 2 "$practice_dir/sample.txt"` |
| `wc` | `wc -l "$practice_dir/sample.txt"` |
| `echo` | `echo "练习目录：$practice_dir"` |
| `nano` | 可选：`nano "$practice_dir/note.txt"`，写一行后按 `Ctrl+O` 保存、`Ctrl+X` 退出 |
| `trash-put` | 可选，先 `touch "$practice_dir/trash-me.txt"`，再运行 `trash-put "$practice_dir/trash-me.txt"` |

#### 权限、用户与进程

```bash
chmod 600 "$practice_dir/sample.txt"
ls -l "$practice_dir/sample.txt"
umask
ps aux | head
pgrep -a bash
pstree -p $$
```

| 命令 | 练习实例 |
|---|---|
| `chmod` | `chmod 644 "$practice_dir/sample.txt"`，再用 `ls -l` 查看权限 |
| `chown` | 可选，需 sudo：`sudo chown "$(id -un):$(id -gn)" "$practice_dir/sample.txt"`，将练习文件所有者设回当前用户 |
| `umask` | `umask` 查看当前掩码；若练习 `umask 077`，只影响当前 shell 后续新建文件，结束后重新打开终端即可恢复 |
| `sudo` | `sudo whoami`，确认提权命令输出的用户名；只在你信任的机器上使用 sudo |
| `su` | 临时账户实验创建账户后运行：`su -c 'whoami' practice-user`；Ubuntu 常默认锁定 root，不要为此启用 root 登录 |
| `adduser` | 管理员练习见下方“临时账户实验”，不要在日常账户上随意创建用户 |
| `passwd` | 在临时账户实验中运行 `sudo passwd practice-user`，输入练习密码后再删除该账户 |
| `usermod` | 临时账户实验中运行 `sudo usermod -aG practice-group practice-user` |
| `userdel` | 临时账户实验最后运行 `sudo userdel -r practice-user` 清理练习账户 |
| `groupadd` | 临时账户实验中运行 `sudo groupadd practice-group` |
| `groupdel` | 临时账户实验最后运行 `sudo groupdel practice-group` 清理练习组 |
| `groups` | `groups` 查看当前用户组；实验后可运行 `groups practice-user` |
| `ps` | `ps aux --sort=-%cpu \| head` |
| `pgrep` | `pgrep -a bash` |
| `pstree` | `pstree -p $$` |
| `top` | 运行 `top`，观察进程列表，按 `q` 退出 |
| `htop` | 可选，安装后运行 `htop`，按 `q` 退出 |
| `kill` | `sleep 60 & practice_pid=$!; kill -TERM "$practice_pid"`，只结束本练习刚启动的 sleep 进程 |
| `killall` | `killall -s 0 sleep` 只检查是否存在 sleep 进程，不发送终止信号 |
| `pkill` | `pkill -0 -f 'no-such-practice-process'`；信号 `0` 只检查匹配，不会终止进程，找不到时返回非零是正常的 |
| `jobs` | `sleep 5 & jobs; wait`，查看后台任务后等待它自然结束 |
| `fg` / `bg` | 运行 `sleep 30`，按 `Ctrl+Z` 挂起；输入 `bg` 后用 `jobs` 查看，再用 `fg` 调回前台并按 `Ctrl+C` 结束 |
| `nohup` | `nohup sh -c 'echo done; sleep 2' > "$practice_dir/nohup.log" 2>&1 &`，随后用 `cat "$practice_dir/nohup.log"` 查看 |
| `tmux` | 可选：`tmux new -s practice` 新建会话；按 `Ctrl+B` 再按 `D` 脱离，最后用 `tmux kill-session -t practice` 清理 |
| `node` | `node -e 'console.log("Node practice")'` |
| `npm` | `npm --version` |
| `nvm` | 可选，已安装 nvm 后运行 `nvm current` 查看当前 Node.js 版本 |

临时账户实验（仅在你有 sudo 权限且明确要练用户管理时执行；用户名和组名若已存在，请换一个独特名称）：

```bash
sudo groupadd practice-group
sudo adduser --disabled-password --gecos "" practice-user
sudo usermod -aG practice-group practice-user
groups practice-user
sudo passwd practice-user
su -c 'whoami' practice-user
sudo userdel -r practice-user
sudo groupdel practice-group
```

#### 网络、服务、日志与磁盘

| 命令 | 练习实例 |
|---|---|
| `ip` | `ip -br a` 查看网卡和地址，不修改网络配置 |
| `ss` | `ss -tuln` 查看监听端口 |
| `lsof` | 可选：`sudo lsof -i :80` 查看 80 端口相关文件描述符 |
| `fuser` | 可选：`tail -f "$practice_dir/sample.txt" & practice_pid=$!; fuser -v "$practice_dir/sample.txt"; kill "$practice_pid"`，先让 tail 打开临时文件再查询，并在最后结束练习进程 |
| `ping` | `ping -c 2 127.0.0.1` 测试本机回环地址 |
| `traceroute` | 可选：`traceroute -m 5 127.0.0.1`；缺少命令时先安装 traceroute 软件包 |
| `mtr` | 可选：`mtr -rw -c 3 127.0.0.1`；缺少命令时先安装 mtr 软件包 |
| `dig` | `dig +short example.com`，需要 DNS/网络可用 |
| `nslookup` | `nslookup example.com`，需要 DNS/网络可用 |
| `curl` | `curl -I https://example.com`，需要网络可用 |
| `telnet` | 可选：`telnet 127.0.0.1 22`；端口未监听时连接失败是正常结果，按 `Ctrl+]` 后输入 `quit` 退出 |
| `nc` | `nc -zv 127.0.0.1 22`；端口未监听时会报告连接失败，不会更改系统 |
| `systemd` | `ps -p 1 -o comm=` 查看 PID 1 是否为 systemd |
| `systemctl` | `systemctl status nginx` 查看服务状态；练习 `start/stop/restart/enable` 前确认是自己的实验服务 |
| `journalctl` | `journalctl -u nginx -n 20 --no-pager` 查看最近日志 |
| `nginx` | `sudo nginx -t` 检查配置；只检查，不会重载服务 |
| `logrotate` | `sudo logrotate -d /etc/logrotate.conf` 做调试演练，不执行实际轮转 |
| `dmesg` | `dmesg \| tail -n 10`；若权限不足，使用 `sudo dmesg \| tail -n 10` |
| `df` | `df -h /` 查看根文件系统空间 |
| `du` | `du -sh "$practice_dir"` 查看练习目录大小 |
| `mount` | `mount \| head` 查看当前挂载；不要对不熟悉的设备执行挂载或卸载 |
| `umount` | `umount --help` 查看帮助；真正卸载前必须确认目标是自己挂载的练习盘，切勿卸载系统盘 |
| `fdisk` | `sudo fdisk -l` 只列出分区信息，不要在练习中执行分区写入操作 |
| `blkid` | `sudo blkid` 查看文件系统 UUID |
| `ufw` | `sudo ufw status verbose` 查看防火墙状态；不要在远程连接中随意启用/重置防火墙 |
| `truncate` | `printf 'temporary data\n' > "$practice_dir/truncate.txt"; truncate -s 0 "$practice_dir/truncate.txt"`，只清空临时文件 |
| `docker` | 可选：`docker system df` 查看 Docker 磁盘使用量；不要把 `system prune` 当作练习清理命令 |
| `iostat` | 可选：`iostat -x 1 2`，需要安装 sysstat |
| `vmstat` | `vmstat 1 2` 查看两次系统统计 |
| `mpstat` | 可选：`mpstat -P ALL 1 2`，需要安装 sysstat |
| `wsl` / `wsl.exe` | 在 Windows PowerShell 中运行 `wsl.exe --list --verbose` 查看发行版；`wsl --shutdown` 会停止所有 WSL 实例，先保存工作 |
| `Optimize-VHD` | 管理员 PowerShell 中先运行 `Get-Command Optimize-VHD` 确认命令可用；实际示例：`Optimize-VHD -Path "D:\WSL\Ubuntu\ext4.vhdx" -Mode Quick`。必须换成自己的 VHDX 路径，先关闭 WSL 并备份磁盘文件 |

#### 文本、归档、软件包与 Shell

```bash
printf 'error 404\ninfo 200\nerror 500\n' > "$practice_dir/app.log"
grep -n 'error' "$practice_dir/app.log"
sed -n '1,2p' "$practice_dir/app.log"
awk '{print $1}' "$practice_dir/app.log"
sort "$practice_dir/app.log" | uniq
printf '%s\n' one two | xargs -n 1 echo item
cat "$practice_dir/app.log" | tee "$practice_dir/copy.log"
tar -czf "$practice_dir/sample.tar.gz" -C "$practice_dir" sample.txt
tar -tzf "$practice_dir/sample.tar.gz"
```

| 命令 | 练习实例 |
|---|---|
| `grep` | `grep -n 'error' "$practice_dir/app.log"` |
| `sed` | `sed 's/error/warning/g' "$practice_dir/app.log"`；结果输出到终端，不会改原文件 |
| `awk` | `awk '{print NR, $1}' "$practice_dir/app.log"` |
| `sort` | `sort "$practice_dir/app.log"` |
| `uniq` | `sort "$practice_dir/app.log" \| uniq -c` |
| `xargs` | `printf '%s\n' one two \| xargs -n 1 echo item` |
| `tee` | `echo practice \| tee "$practice_dir/tee.txt"` |
| `tar` | `tar -czf "$practice_dir/sample.tar.gz" -C "$practice_dir" sample.txt; tar -tzf "$practice_dir/sample.tar.gz"` |
| `gzip` | `gzip -k "$practice_dir/sample.txt"`，`-k` 保留原文件 |
| `zip` / `unzip` | 可选：`zip "$practice_dir/sample.zip" "$practice_dir/sample.txt"; unzip -l "$practice_dir/sample.zip"` |
| `apt` | `apt show nginx` 或 `apt search nginx`；练习查询，不安装或升级软件 |
| `dpkg` | `dpkg -l \| head; dpkg -S "$(command -v ls)"` |
| `seq` | `seq 1 5` |
| `sleep` | `sleep 2`，等待两秒后返回 |
| `env` | `env \| grep '^HOME='` |
| `export` / `unset` | `export PRACTICE_WORD=hello; echo "$PRACTICE_WORD"; unset PRACTICE_WORD` |
| `alias` / `unalias` | `alias practice_ls='ls -lah'; practice_ls; unalias practice_ls`（在交互式 Bash 中练习） |
| `history` | `history \| tail -n 10` |
| `source` | `printf 'PRACTICE_FROM_FILE=loaded\n' > "$practice_dir/vars.sh"; source "$practice_dir/vars.sh"; echo "$PRACTICE_FROM_FILE"` |
| `command` | `command -v ls` 查询 `ls` 是否可用 |
| `test` / `[` | `[ -f "$practice_dir/sample.txt" ] && echo '文件存在'` |
| `man` | `man ls`，按 `q` 退出 |
| `bash` | `bash -c 'echo Bash practice'` |
| `sysstat` | `dpkg -s sysstat` 查看软件包是否安装；未安装时按前文命令安装后再练 `iostat` 和 `mpstat` |

练完后可安全清理本节创建的临时目录：

```bash
rm -rf -- "$practice_dir"
```

此清理命令只适用于本节开头由 `mktemp -d` 创建且未被你改写的 `practice_dir` 变量；执行前可先运行 `printf '%s\n' "$practice_dir"` 确认路径位于 `/tmp`。

---

## 学习路径建议

**第 1 天**：第 1-3 章。练熟 `ls` / `cd` / `cp` / `mv` / `chmod`。
目标：不查资料完成文件复制和权限修改。

**第 2 天**：第 5-6 章。重点练 `ps` / `ss` / `curl` 排查组合。
目标：能独立回答"服务为什么访问不了"。

**第 3 天**：第 7-8 章。给本项目的 Node 服务写 systemd unit。
目标：能解释 unit 文件里每一行的作用。

**第 4 天**：第 10 章 + 第 14 章实战。
目标：完整在 Ubuntu 跑通项目，能演示负载均衡的四种策略。

**第 5 天**：第 13-15 章。练 Shell 技巧，演练故障排查。
目标：拿到任何一个报错，能按决策树一步步定位。

---

## 推荐练习命令（可直接复制）

```bash
# 一键做一遍基础练习
echo "=== 系统信息 ===" && lsb_release -a && uname -r && nproc && free -h && df -h /

echo "=== 我的家目录 ===" && ls -la ~ && du -sh ~

echo "=== 当前用户 ===" && whoami && id && echo "sudo 组: " && groups

echo "=== 监听端口 ===" && sudo ss -tulnp

echo "=== 进程 top10 ===" && ps aux --sort=-%cpu | head -11

echo "=== 最大目录 ===" && du -h --max-depth=1 /var 2>/dev/null | sort -rh | head

echo "=== 失败的 systemd 服务 ===" && systemctl --failed
```

**把所有失败的 systemd 服务列出来**，是发现系统隐患最快的方式。
