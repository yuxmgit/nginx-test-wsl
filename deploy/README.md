# WSL Ubuntu 部署指南

把 Nginx 负载均衡项目从 Windows 部署到 WSL Ubuntu 的完整方案。

---

## 前置条件

### 1. 确认 WSL 已安装

在 **PowerShell**（不是 cmd）里执行：

```powershell
wsl --status
wsl -l -v
```

如果没装：
```powershell
wsl --install -d Ubuntu-22.04
```

### 2. 启用 systemd（重要）

WSL 默认不启用 systemd，服务无法被 `systemctl` 管理。

**步骤 1**：在 Windows 里创建/编辑 `%UserProfile%\.wslconfig`

```ini
[wsl2]
systemd=true
memory=4GB
processors=4
```

**步骤 2**：关闭 WSL 让配置生效

```powershell
wsl --shutdown
```

**步骤 3**：重新进入 Ubuntu 验证

```bash
ps -p 1 -o comm=
# 输出 systemd = 成功
# 输出 init 或 sh = 未生效，检查上面的 .wslconfig
```

### 3. 安装 Node.js

```bash
sudo apt update
sudo apt install -y curl build-essential

curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/master/install.sh | bash
source ~/.bashrc
nvm install 22
nvm use 22
node -v && npm -v
```

用 nvm 而不是 apt 装 Node，好处是能随时切换版本。

---

## 一键部署

```bash
cd /mnt/i/练习/nginx
bash deploy/deploy.sh
```

脚本会自动完成：

1. 环境检查（Node / Nginx / systemd）
2. 项目拷贝到 `~/nginx-project`（**不在 /mnt/i 下跑**，跨系统 IO 太慢）
3. 写入 Ubuntu 版 nginx.conf（Windows 路径 `I:/练习/nginx/frontend` 必须改成 Linux 路径）
4. `nginx -t` 语法检查并启动
5. 创建 `api-server1/2.service`，交由 systemd 托管
6. curl 连续 6 次验证负载均衡

---

## 手动部署（想理解每一步就手动来）

### 1. 拷贝项目

```bash
mkdir -p ~/nginx-project
cp -a /mnt/i/练习/nginx/backend ~/nginx-project/
cp -a /mnt/i/练习/nginx/frontend ~/nginx-project/
mkdir -p ~/nginx-project/logs
```

> 为什么要拷贝而不是直接在 /mnt/i 跑？
> `/mnt/c`、`/mnt/i` 是 Windows 磁盘通过 9p 协议挂载的，文件读写比 Linux
> 原生文件系统慢 5-20 倍，Node 加载模块会非常慢，甚至触发文件监听超时。

### 2. 先前台验证

```bash
cd ~/nginx-project
node backend/api-server1.js
# 另开终端
node backend/api-server2.js
# 再开一个
curl -s http://127.0.0.1:4001/api/user
```

能返回 JSON 就说明后端本身没问题。

### 3. 改 Nginx 配置

Windows 那份配置里的 `root I:/练习/nginx/frontend;` 在 Linux 里无效。

```bash
sudo nano /etc/nginx/sites-available/nginx-app
```

内容：

```nginx
server {
    listen 80;
    listen [::]:80;
    server_name localhost;

    location / {
        root /home/你的用户名/nginx-project/frontend;
        index index.html;
        try_files $uri $uri/ /index.html;
    }

    location /api/ {
        proxy_pass http://api_backend;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

**upstream 块必须放在 `http {}` 内部**（Ubuntu 在 `/etc/nginx/nginx.conf`）：

```bash
sudo nano /etc/nginx/nginx.conf
# 找到 http { ，在下面插入：
#
#   upstream api_backend {
#       server 127.0.0.1:4001;
#       server 127.0.0.1:4002;
#   }
```

启用站点：

```bash
sudo ln -sf /etc/nginx/sites-available/nginx-app /etc/nginx/sites-enabled/nginx-app
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t                    # 必做！语法检查
sudo systemctl reload nginx
```

### 4. 后端交给 systemd

```bash
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
```

server2 复制一份改名字即可。

```bash
sudo systemctl daemon-reload     # 改过 unit 文件后必做
sudo systemctl enable api-server1 api-server2
sudo systemctl start api-server1 api-server2
systemctl status api-server1 api-server2
```

---

## 验证

```bash
# 端口状态
ss -tlnp | grep -E ':80|:4001|:4002'
# 应看到 nginx 监听 80，两个 node 各监听 4001/4002

# 直连后端（绕过 Nginx）
curl -s http://127.0.0.1:4001/api/user
curl -s http://127.0.0.1:4002/api/user

# 通过 Nginx 连续 10 次
for i in $(seq 1 10); do
    curl -s http://localhost/api/user | grep -o '"server":"[^"]*"'
done

# 统计比例
for i in $(seq 1 20); do curl -s http://localhost/api/user; echo; done \
  | grep -o '服务器[AB]' | sort | uniq -c
# 预期大约 10 : 10
```

浏览器打开 `http://localhost` 用前端页面点按钮，更直观。

> 浏览器有 keep-alive 缓存，多次刷新可能都落在同一台。
> 用无痕窗口，或用上面的 curl 命令测试更准确。

---

## 运维速查

| 需求 | 命令 |
|---|---|
| 看后端状态 | `systemctl status api-server1 api-server2` |
| 看后端日志 | `journalctl -u api-server1 -f` |
| 重启后端 | `sudo systemctl restart api-server1 api-server2` |
| 改 Nginx 后重载 | `sudo nginx -t && sudo systemctl reload nginx` |
| Nginx 错误日志 | `sudo tail -f /var/log/nginx/error.log` |
| 端口占用 | `ss -tlnp \| grep -E ':80\|:4001\|:4002'` |
| 改负载策略 | `sudo nano /etc/nginx/nginx.conf` |
| 找大文件 | `du -h --max-depth=1 /var \| sort -rh \| head` |

---

## WSL 特有的坑

### 1. IP 会变

```bash
hostname -I
```

WSL 重启后 IP 就变了。要固定可以：

```powershell
# PowerShell（在 WSL 里执行）
wsl hostname -I | % { $_ }
```

或配 `/etc/wsl.conf` 固定网络：
```ini
[network]
generateResolvConf = false
```

### 2. 不是真正的开机自启

WSL 不启动，里面的服务就不会运行。Windows 侧用任务计划程序：

```powershell
# 需要管理员 PowerShell，注册一个开机任务
$action = New-ScheduledTaskAction `
  -Execute "wsl.exe" `
  -Argument "-d Ubuntu-22.04 -u root /bin/true"
$trigger = New-ScheduledTaskTrigger -AtStartup
Register-ScheduledTask -TaskName "WSL-Nginx-AutoStart" `
  -Action $action -Trigger $trigger `
  -RunLevel Highest
```

### 3. 磁盘只会变大

WSL 的 ext4.vhdx 不自动收缩。清理：

```bash
# Ubuntu 里
sudo apt clean
sudo apt autoremove
sudo truncate -s 0 /var/log/syslog
```

```powershell
# 管理员 PowerShell
wsl --shutdown
Optimize-VHD -Path "$env:LOCALAPPDATA\Packages\CanonicalGroupLimited...\ext4.vhdx" -Mode Full
```

### 4. 文件权限警告

WSL 挂载的 Windows 文件权限会显示成 777，脚本里加个判断：

```bash
mount | grep -q "9p\|drvfs" && echo "在 Windows 挂载盘上"
```

---

## 卸载

```bash
bash deploy/uninstall.sh
# 或彻底卸载 Nginx
sudo apt purge nginx
```
