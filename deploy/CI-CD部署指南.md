# GitHub + Jenkins 自动部署完整教程

> 项目：Nginx 负载均衡（frontend 静态页 + backend 两个 Node API 服务，4001/4002）
> 部署目标：WSL Ubuntu（`~/nginx-project`）
> GitHub 仓库：`https://github.com/yuxmgit/nginx-test-wsl.git`（已创建，remote 已配置）
> 适用读者：已经能在 WSL 里手动跑 `bash deploy/deploy.sh` 的同学

---

## ⚡ 你的当前状态速览

| 项目 | 状态 |
|---|---|
| Git 仓库 | ✅ 已初始化，分支 `main` |
| 远程 origin | ✅ `https://github.com/yuxmgit/nginx-test-wsl.git` |
| 已有提交 | ✅ `first commit` + `Refactor code structure...` |
| `.gitignore` | ✅ 已配置（排除 nginx 源码/二进制、日志、密钥、`.workbuddy/`） |
| `Jenkinsfile` | ✅ 已就位（仓库根目录） |
| `deploy/ci-deploy.sh` | ✅ 已就位（无人值守部署 + 自动回滚） |
| **待办 1** | ⚠️ 首次推送需配置代理（见第 0 章） |
| **待办 2** | ⚠️ WSL 里安装 Jenkins（第 4 章） |
| **待办 3** | ⚠️ 配置凭据 + 免密 sudo（第 6、7 章） |
| **待办 4** | ⚠️ 创建 Pipeline 任务（第 8 章） |

---

## 第 0 章：先把代码推上 GitHub（你的环境有代理问题）

### 0.1 你会遇到什么

已实测确认你的网络环境：

```
$ git push -u origin main
fatal: unable to access 'https://github.com/yuxmgit/nginx-test-wsl.git/':
CONNECT tunnel failed, response 502
```

**根因**（已逐项排查）：

| 检查项 | 结果 |
|---|---|
| Windows 系统代理配置 | `ProxyServer = 127.0.0.1:7890`，但 `ProxyEnable = 0` |
| 7890 端口监听 | ❌ **未监听** —— 代理软件（Clash / Verge / V2Ray 等）当前没启动 |
| 直连 github.com:443 | ❌ 超时（无返回码） |
| 走环境变量代理（WorkBuddy 内部 52670） | ❌ `CONNECT tunnel failed, 502`（内部代理不放行 github） |
| SSH 22 端口 | ❌ 不通 |

**结论：你的代理软件没开。** 这是推送失败的根本原因，不是 Git 配置问题。

### 0.2 方案 A：启动代理软件后推送（推荐）

**第 1 步：启动你的代理软件**（Clash Verge / V2RayN / Shadowsocks 等），确保它正常连上。

**第 2 步：跑诊断脚本**（自动探测端口 + 测试连通 + 配置代理）：

```bash
cd /mnt/i/练习/nginx        # 或 Windows Git Bash 里 cd /i/练习/nginx
bash deploy/git-proxy-check.sh
```

脚本会依次做：读当前代理配置 → 扫 12 个常见代理端口 → 用找到的端口测试 GitHub → 验证 `git ls-remote`。
全绿时输出：

```
[ok] 端口 7890 正在监听
[ok] 代理 http://127.0.0.1:7890 可访问 GitHub
[ok] 仓库可达，可以执行： git push -u origin main
```

如果一个端口都没扫到，会直接告诉你"请先启动代理软件"。

**第 3 步：自动配置并验证**：

```bash
bash deploy/git-proxy-check.sh --set 7890
```

`--set` 会用**仓库级**配置（`git config --local`），只影响这个项目，不会干扰你公司内网的 GitLab。
想用全局配置就手动执行：

```bash
git config --global http.proxy  http://127.0.0.1:7890
git config --global https.proxy http://127.0.0.1:7890
```

**第 4 步：推送**：

```bash
git push -u origin main
```

> **端口号要改成你实际的**。系统代理设置里写的是 7890，但如果你的软件用的是别的端口
> （Clash Verge 默认 7897，V2RayN 默认 10809），以软件界面显示的为准。
>
> **如果代理是 SOCKS5 协议**（不是 HTTP），要用：
> ```bash
> git config --global http.proxy  socks5h://127.0.0.1:1080
> git config --global https.proxy socks5h://127.0.0.1:1080
> ```

**取消代理**（`--unset` 会同时清掉仓库级和全局级）：

```bash
bash deploy/git-proxy-check.sh --unset
```

### 0.2.1 让 Git 只对这个仓库走代理（更干净）

全局代理会影响所有 Git 操作，包括公司内网的 GitLab。改用仓库级配置：

```bash
cd /i/练习/nginx
git config --local http.proxy  http://127.0.0.1:7890
git config --local https.proxy http://127.0.0.1:7890
```

### 0.3 方案 B：走 SSH 22 端口

如果你的代理软件支持"允许 SSH 流量"（Clash Verge 有 `Allow LAN` 和 TUN 模式），可以走 SSH：

```bash
# 生成密钥（Windows Git Bash）
ssh-keygen -t ed25519 -C "yuxiangming@ata.net.cn"
cat ~/.ssh/id_ed25519.pub
```

把公钥加到 GitHub → Settings → SSH and GPG keys，然后：

```bash
git remote set-url origin git@github.com:yuxmgit/nginx-test-wsl.git
git push -u origin main
```

> 前提是 22 端口能通。刚才实测**当前不通**，所以这条路要等代理支持 SSH 流量后才能走。

### 0.4 方案 C：手动上传（最笨但最可靠）

GitHub 仓库页面 → **Add file** → **Upload files**，把 `backend/`、`frontend/`、`deploy/`、`Jenkinsfile`、`.gitignore`、`.gitattributes` 拖上去。
缺点：只有一次性快照，后续没有 git 历史，不推荐长期用。

### 0.5 认证

`git push` 时如果提示输入密码：

- **Username**：你的 GitHub 用户名（`yuxmgit`）
- **Password**：粘贴第 2.2 节生成的 PAT（**不是登录密码**）

### 0.6 推送

```bash
cd /i/练习/nginx
git add .
git status              # 确认要提交的文件
git commit -m "ci: 添加 Jenkinsfile 与 CI 自动部署脚本"
git push -u origin main
```

> **注意**：`git push -u origin main` 会把当前 `main` 推上去。
> 远程仓库已有 2 个提交，你本地也是这 2 个提交 + 新的，所以是 fast-forward，不会冲突。
> `-u` 参数必须带 —— 你本地 `main` 目前没有 upstream，不带会报
> `fatal: The current branch main has no upstream branch`。

---

## 目录

- [第 0 章：先把代码推上 GitHub](#第-0-章先把代码推上-github你的环境有代理问题)
- [第 1 章：先想清楚架构](#第-1-章先想清楚架构)
- [第 2 章：准备 GitHub 仓库](#第-2-章准备-github-仓库)
- [第 3 章：本地 Git 初始化与首次推送](#第-3-章本地-git-初始化与首次推送)
- [第 4 章：在 WSL Ubuntu 里安装 Jenkins](#第-4-章在-wsl-ubuntu-里安装-jenkins)
- [第 5 章：Jenkins 首次配置](#第-5-章jenkins-首次配置)
- [第 6 章：配置 GitHub 凭据](#第-6-章配置-github-凭据)
- [第 7 章：配置免密 sudo（关键）](#第-7-章配置免密-sudo关键)
- [第 8 章：创建 Jenkins 任务](#第-8-章创建-jenkins-任务)
- [第 9 章：配置 Webhook 实现推送即部署](#第-9-章配置-webhook-实现推送即部署)
- [第 10 章：验证与排错](#第-10-章验证与排错)
- [附录 A：完整命令速查](#附录-a完整命令速查)
- [附录 A-1：最短路径行动清单](#附录-a-1最短路径行动清单照着做就行)
- [附录 B：常见报错对照表](#附录-b常见报错对照表)

---

## 本方案涉及的文件

| 文件 | 作用 |
|---|---|
| `Jenkinsfile` | 流水线定义，Jenkins 从仓库根目录读取 |
| `deploy/ci-deploy.sh` | 无人值守部署 + 健康检查 + 自动回滚 |
| `deploy/jenkins-setup.sh` | Jenkins 一键安装 + 免密 sudo + SSH 密钥 |
| `deploy/git-proxy-check.sh` | GitHub 连通性诊断 + 代理自动配置 |
| `deploy/CI-CD部署指南.md` | 本文档 |
| `.gitignore` | 排除 nginx 二进制、日志、密钥、`.workbuddy/` |
| `.gitattributes` | 统一换行符为 LF（WSL 执行 .sh 的前提） |

---

## 第 1 章：先想清楚架构

### 1.1 数据流

```
   你在 Windows 上改代码
            │
            ▼
   git push  →  GitHub 仓库（main 分支）
            │
            │  ① Webhook 通知（Jenkins 主动轮询 GitHub）
            ▼
        Jenkins（跑在同一个 WSL Ubuntu 里）
            │
            │  ② git clone 到 workspace
            │  ③ node --check 语法预检
            │  ④ rsync 同步到 ~/nginx-project（自动备份旧版）
            │  ⑤ systemctl restart api-server1/2 + nginx reload
            │  ⑥ 健康检查（4001/4002/nginx 各 200 才算成功）
            ▼
   浏览器 http://localhost  →  看到新版本
```

### 1.2 关键设计决策（为什么这么选）

| 决策 | 理由 |
|---|---|
| **Jenkins 也装在 WSL Ubuntu 里** | 部署目标是本机，Jenkins 装在本机就不用处理跨机 SSH 推送、免密登录、端口转发等一系列问题。学习阶段收益最高。 |
| **用 rsync 而不是 cp** | `--delete` 能真正删除目标端已删除的文件，`cp` 做不到；配合 `backup/` 目录实现一键回滚。 |
| **部署前先 `node --check`** | 语法错误在推送阶段就暴露，而不是等重启后服务起不来。 |
| **健康检查失败自动回滚** | 真正的"自动化"必须包含失败保护，否则会把线上打挂。 |
| **配置文件不入库** | `deploy/ci-deploy.sh` 里的路径、用户名通过环境变量注入，改路径不用改代码。 |

### 1.3 环境依赖清单

| 组件 | 版本 | 用途 | 检查命令 |
|---|---|---|---|
| Node.js | 22.x | 跑后端 | `node -v` |
| Nginx | 1.24+ | 反向代理 + 静态站 | `nginx -v` |
| Java (JRE) | 17 或 21 | Jenkins 运行时 | `java -version` |
| Jenkins | 2.4xx LTS | CI 服务器 | `jenkins --version` |
| rsync | 任意 | 文件同步 | `rsync --version` |
| Git | 2.3x+ | 拉代码 | `git --version` |
| systemd | — | 管理服务（WSL 必开） | `ps -p 1 -o comm=` |

> **WSL 提醒**：Jenkins 装在 WSL 里意味着 **Windows 重启后 Jenkins 不会自动运行**。
> 第 4.6 节会给出用任务计划程序让 WSL + Jenkins 开机自启的方案。

---

## 第 2 章：准备 GitHub 仓库

### 2.1 创建仓库

1. 打开 <https://github.com/new>
2. 仓库名填 `nginx-project`（或你喜欢的名字）
3. **Public / Private 建议选 Private**（学习阶段也选 Private，安全习惯要养成）
4. ⚠️ **不要勾选** `Add a README file`、`.gitignore`、`license`
   —— 勾了会产生初始 commit，和你本地的提交历史对不上，`push` 时会报 `rejected (non-fast-forward)`
5. 点 **Create repository**

### 2.2 生成 Personal Access Token（如果用 HTTPS）

1. 右上角头像 → **Settings** → 最下面 **Developer settings**
2. 左侧 **Personal access tokens** → **Tokens (classic)** → **Generate new token (classic)**
3. Note 填 `nginx-deploy`，Expiration 选 90 days
4. **勾选 `repo`** 权限（私有库需要），其他不用勾
5. 点底部 **Generate token**
6. ⚠️ **token 只显示一次**，立刻复制保存，形如 `ghp_xxxxxxxxxxxxxxxxxxxx`
7. 之后用 token 代替密码：`git push` 时 Username 填 GitHub 用户名，Password 粘贴 token

> **Token 泄露了怎么办**：回到该页面点 **Regenerate token** 立即作废旧的。

### 2.3 准备 SSH 密钥（推荐方式，Jenkins 拉代码更省事）

在 **WSL Ubuntu** 里执行（不是 Windows Git Bash）：

```bash
# 1) 如果没有密钥就生成（跳过已有提示一路回车）
ls -l ~/.ssh/id_ed25519 2>/dev/null || ssh-keygen -t ed25519 -C "yuxiangming@ata.net.cn"

# 2) 复制公钥内容
cat ~/.ssh/id_ed25519.pub
```

把输出的一整行（以 `ssh-ed25519` 开头）复制，然后：

1. GitHub → **Settings** → **SSH and GPG keys** → **New SSH key**
2. Title 填 `WSL-Ubuntu`，Key 粘贴刚才复制的公钥 → **Add SSH key**
3. 测试连通性：

```bash
ssh -T git@github.com
# 首次会问 yes/no，输 yes
# 成功输出：Hi yuxiangming! You've successfully authenticated...
```

> 已经有 Windows 侧 `~/.ssh/config` 的话，注意别和 WSL 里的冲突。WSL 和 Windows 的 `.ssh` 是两套独立目录。

---

## 第 3 章：本地 Git 初始化与首次推送

### 3.1 关键决策：在哪台机器上执行 git？

| 方案 | 说明 | 推荐度 |
|---|---|---|
| **A. 在 WSL Ubuntu 里操作** | 直接管理 `~/nginx-project`，不用跨系统拷贝 | ⭐⭐⭐ 推荐 |
| B. 在 Windows 里操作 `I:\练习\nginx` | 项目源在 Windows，Jenkins 在 WSL 拉的是 WSL 侧的仓库 | ⭐⭐ 需同步两份，容易乱 |

**方案 A 的问题**：`~/nginx-project` 是部署产物目录，Jenkins 会往里面 rsync 覆盖。如果 git 仓库也放那儿，会互相干扰。

**推荐做法**：

```
WSL Ubuntu:
  ~/nginx-project        ← 部署产物（由 ci-deploy.sh 管理，不要 git init 在这）
  ~/dev/nginx-project    ← Git 工作区（你在这里改代码、commit、push）
```

如果你日常在 Windows 的 VSCode 里写代码（看截图你就是在 VSCode 写的），那就用方案 B，WSL 侧单独 clone 一份给 Jenkins 用：

```bash
# 在 WSL Ubuntu 里
mkdir -p ~/dev && cd ~/dev
git clone https://github.com/yuxmgit/nginx-test-wsl.git
```

**下面教程以"Windows 编辑 + WSL 部署"的组合为主线**，这是你现在的实际状态。

### 3.2 仓库初始化（✅ 已完成）

你的仓库**已经初始化好了**，无需重复执行。现状如下：

```bash
cd /i/练习/nginx

git branch -vv
# * main 62fec71 Refactor code structure for improved readability and maintainability

git remote -v
# origin  https://github.com/yuxmgit/nginx-test-wsl.git (fetch)
# origin  https://github.com/yuxmgit/nginx-test-wsl.git (push)

git log --oneline
# 62fec71 Refactor code structure for improved readability and maintainability
# 71fe358 first commit
```

已配置的身份：

| 项 | 值 |
|---|---|
| `user.name` | `yuxiangming` |
| `user.email` | `yuxiangming@ata.net.cn` |
| 默认分支 | `main`（已从 master 重命名过） |

> ⚠️ **一个坑**：`main` 分支目前**没有设置 upstream**（`git branch -vv` 里没有 `-> origin/main`），
> 所以直接 `git push` 会报 `fatal: The current branch main has no upstream branch`。
> 第 0.6 节的 `git push -u origin main` 里的 `-u` 就是解决这个的。

### 3.3 关联远程仓库并推送（⏳ 待办）

`remote origin` 已配置好，**不需要再执行 `git remote add`**（重复执行会报 `remote origin already exists`）。

只需要完成首次推送，见 **第 0 章**。完整的首次推送流程：

```bash
cd /i/练习/nginx

# 1) 先配代理（否则会报 CONNECT tunnel failed 502）
git config --global http.proxy  http://127.0.0.1:7890   # 换成你的实际代理端口
git config --global https.proxy http://127.0.0.1:7890

# 2) 验证连通
git ls-remote origin

# 3) 提交本次新增的 CI/CD 文件
git add .
git status              # 确认清单
git commit -m "ci: 添加 Jenkinsfile、CI 自动部署脚本与部署指南"

# 4) 推送并建立 upstream
git push -u origin main
```

推送成功后打开 GitHub 仓库页面，应该能看到 `backend/`、`frontend/`、`deploy/`、`Jenkinsfile`、`.gitignore` 这几个目录/文件。

> **`git add .` 之前务必 `git status` 看一眼**。`.gitignore` 已经排除了
> `nginx-1.27.2/`、`nginx.zip`、`*.log`、`.workbuddy/`、`outputs/`，
> 但养成"先看再提交"的习惯能避免把 2MB 的二进制塞进仓库。

### 3.4 验证 SSH 免密（如果用 SSH）

```bash
ssh -T git@github.com
```

如果报 `Permission denied (publickey)`，检查：

```bash
ssh -vT git@github.com 2>&1 | grep -i "offering\|identity file"   # 看它尝试了哪些密钥
ssh-add -l                                                # 看 agent 里的密钥
```

---

## 第 4 章：在 WSL Ubuntu 里安装 Jenkins

> **最省事的做法**：直接跑一键脚本，它把本章 4.1~4.4 + 第 7 章的免密 sudo 全部做完：
>
> ```bash
> cd /mnt/i/练习/nginx
> sudo bash deploy/jenkins-setup.sh
> ```
>
> 下面 4.1~4.7 是脚本背后的手动步骤，帮你理解每一步在干什么。

### 4.1 确认 systemd 已启用（前提条件）

```bash
ps -p 1 -o comm=
# 必须输出 systemd
```

不是 `systemd` 就先改 `%UserProfile%\.wslconfig`：

```ini
[wsl2]
systemd=true
memory=4GB
processors=4
```

然后在 PowerShell 执行 `wsl --shutdown`，重进 Ubuntu 再验证。

### 4.2 安装 Java

Jenkins 2.4xx 需要 Java 17 或 21：

```bash
sudo apt update
sudo apt install -y fontconfig openjdk-17-jre curl
java -version
```

### 4.3 添加 Jenkins 软件源并安装

```bash
# 添加 GPG 公钥
sudo curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key \
  | sudo tee /usr/share/keyrings/jenkins.io-2023.key > /dev/null

# 添加源
echo "deb [signed-by=/usr/share/keyrings/jenkins.io-2023.key] https://pkg.jenkins.io/debian-stable binary/" \
  | sudo tee /etc/apt/sources.list.d/jenkins.list > /dev/null

# 安装
sudo apt update
sudo apt install -y jenkins

# 确认已注册为 systemd 服务
systemctl list-unit-files | grep jenkins
```

> **代理环境注意**：WSL 里的 Ubuntu 通常**不走** Windows 的代理。
> 如果 WSL 里 `apt update` 或 `curl` 到 GitHub 超时，需要在 WSL 里单独配代理：
>
> ```bash
> # 在 WSL 里设置（127.0.0.1 是 Windows 主机，WSL2 需用主机 IP）
> export http_proxy=http://$(ip route show default | awk '{print $3}'):7890
> export https_proxy=$http_proxy
>
> # 写进 ~/.bashrc 让 apt 和后续命令都生效
> cat >> ~/.bashrc << 'EOF'
> export http_proxy=http://$(ip route show default | awk '{print $3}'):7890
> export https_proxy=$http_proxy
> export no_proxy=localhost,127.0.0.1
> EOF
>
> # apt 需要单独的代理配置
> sudo tee /etc/apt/apt.conf.d/99proxy > /dev/null << 'EOF'
> Acquire::http::Proxy "http://<Windows主机IP>:7890";
> Acquire::https::Proxy "http://<Windows主机IP>:7890";
> EOF
> ```
>
> 装完 Jenkins 后记得把代理从 `~/.bashrc` 里注释掉，否则 Jenkins 的 git clone 走代理可能出问题。

### 4.4 启动 Jenkins

```bash
sudo systemctl enable jenkins      # 开机自启
sudo systemctl start jenkins       # 立即启动
sudo systemctl status jenkins     # 查看状态

# 实时日志（首次启动会慢一点，看到 "Jenkins is fully up and running" 即可）
sudo journalctl -u jenkins -f
```

按 `Ctrl+C` 退出日志跟踪。

### 4.5 初始密码与安全设置

```bash
sudo cat /var/lib/jenkins/secrets/initialAdminPassword
```

复制这串密码，浏览器打开 <http://localhost:8080>：

1. 粘贴初始密码 → Continue
2. 推荐选 **Install suggested plugins**（会一并装上 Git、Pipeline、Credentials 等）
3. 创建管理员账号（**记下密码**）
4. 实例配置 → 完成

> **8080 端口打不开？**
> - 确认服务在跑：`systemctl status jenkins`
> - WSL2 默认支持 localhost 转发，Windows 浏览器一般能直接访问
> - 打不开就在 Windows 管理员 PowerShell 加一条端口转发：
>   ```powershell
>   New-NetFirewallRule -DisplayName "WSL Jenkins 8080" -Direction Inbound -LocalPort 8080 -Protocol TCP -Action Allow
>   ```

### 4.6 让 WSL + Jenkins 开机自启（可选但推荐）

WSL 不像虚拟机，不存在"开机自启"这回事。解决方案是让 Windows 开机时拉起 WSL：

在 **Windows 管理员 PowerShell** 执行：

```powershell
$action = New-ScheduledTaskAction -Execute "wsl.exe" -Argument "-d Ubuntu-22.04 -u root /bin/true"
$trigger = New-ScheduledTaskTrigger -AtStartup
Register-ScheduledTask -TaskName "WSL-Nginx-AutoStart" -Action $action -Trigger $trigger -RunLevel Highest
```

> 发行版名字用 `wsl -l -v` 查到的实际名字（可能是 `Ubuntu` 而不是 `Ubuntu-22.04`）。

---

## 第 5 章：Jenkins 首次配置

### 5.1 必要的插件

`Manage Jenkins` → `Plugins` → `Available` 里确认这几个装了（安装建议插件时一般已包含）：

| 插件 | 用途 | 必须 |
|---|---|---|
| Git | git checkout | ✅ |
| Pipeline | 流水线 | ✅ |
| Credentials | 凭据管理 | ✅ |
| SSH Agent / SSH Credentials | 用私钥拉仓库 | 建议 |
| GitHub Branch Source | 多分支 + Webhook 自动触发 | 建议 |
| GitHub | Webhook 通知插件 | 建议 |
| Pipeline: GitHub Groovy Libraries | 读取仓库里的 Jenkinsfile | 可选 |
| Build Timeout | 防止构建卡死 | 可选 |

### 5.2 全局配置里的两个必改项

`Manage Jenkins` → `System`：

**① Node 名称（PATH）**
`PATH` 项里加上 Node 和其它工具的路径，Jenkins 才能找到 `node`：

```
/home/yuxiangming/.nvm/versions/node/v22.14.0/bin
/usr/local/bin:/usr/bin:/bin
```

> 你用 nvm 装的 Node，路径里带版本号，升级 Node 后这里要同步改。
> 更稳的做法是给 Node 装个软链：`sudo ln -sf $(which node) /usr/local/bin/node`。

**② 保持 SSH agent 运行**
勾选 **SSH Agent** 插件，并在全局配置里勾上 "Enable SSH Agent"。

---

## 第 6 章：配置 GitHub 凭据

### 6.1 方式一：SSH 私钥（推荐）

**步骤 1** 在 Jenkins 添加凭据：

`Manage Jenkins` → `Credentials` → `(全局)` → `添加凭据`

| 字段 | 填写 |
|---|---|
| Kind | `SSH Username with private key` |
| ID | `github-ssh` ← **记住这个 ID，Jenkinsfile 里要用** |
| Username | `git` |
| Private Key | `Enter directly` → 粘贴 `~/.ssh/id_ed25519` 的**私钥**内容 |

**步骤 2** 确认 jenkins 用户能读到密钥：

```bash
sudo mkdir -p /var/lib/jenkins/.ssh
sudo cp ~/.ssh/id_ed25519 /var/lib/jenkins/.ssh/
sudo chown -R jenkins:jenkins /var/lib/jenkins/.ssh
sudo chmod 700 /var/lib/jenkins/.ssh
sudo chmod 600 /var/lib/jenkins/.ssh/id_ed25519
```

**步骤 3** 测试（在 Jenkins 任务里跑）：

```bash
sudo -u jenkins ssh -T git@github.com
```

### 6.2 方式二：用户名 + Token

`添加凭据` → Kind 选 `Username with password`：

| 字段 | 填写 |
|---|---|
| ID | `github-credentials` |
| Username | 你的 GitHub 用户名 |
| Password | 第 2.2 节生成的 PAT（`ghp_...`） |

---

## 第 7 章：配置免密 sudo（关键）

Jenkins 以 `jenkins` 用户运行，要执行 `systemctl restart`、`nginx -t` 就得免密 sudo。

```bash
sudo visudo -f /etc/sudoers.d/jenkins
```

写入（**用 `visudo` 校验语法，写错会导致 sudo 整个挂掉**）：

```sudoers
# Jenkins 自动部署专用
jenkins ALL=(ALL) NOPASSWD: /bin/systemctl restart api-server1 api-server2
jenkins ALL=(ALL) NOPASSWD: /bin/systemctl reload nginx
jenkins ALL=(ALL) NOPASSWD: /bin/systemctl restart nginx
jenkins ALL=(ALL) NOPASSWD: /bin/systemctl status api-server1 api-server2
jenkins ALL=(ALL) NOPASSWD: /bin/systemctl status nginx
jenkins ALL=(ALL) NOPASSWD: /bin/systemctl daemon-reload
jenkins ALL=(ALL) NOPASSWD: /usr/sbin/nginx -t
jenkins ALL=(ALL) NOPASSWD: /usr/bin/rsync *
jenkins ALL=(ALL) NOPASSWD: /bin/mkdir *
jenkins ALL=(ALL) NOPASSWD: /bin/cp -a *
jenkins ALL=(ALL) NOPASSWD: /bin/rm -rf *
jenkins ALL=(ALL) NOPASSWD: /usr/bin/journalctl *
jenkins ALL=(ALL) NOPASSWD: /usr/bin/tail *
```

```bash
sudo chmod 440 /etc/sudoers.d/jenkins
sudo visudo -c    # 校验全部 sudoers 语法
```

**测试**：

```bash
sudo -u jenkins sudo -n systemctl restart api-server1
# 不报错就说明配好了
```

> ⚠️ `/bin/rm -rf *` 这条权限很大。生产环境应该改成更精确的路径白名单，
> 或者给 Jenkins 单独建一个部署用户组。学习阶段可以先这么用，但心里要有数。

---

## 第 8 章：创建 Jenkins 任务

### 8.1 新建 Pipeline 任务

1. 首页 → 左侧 **New Item**
2. 名称：`nginx-deploy`，类型选 **Pipeline** → OK
3. 下拉到 **Pipeline** 区域：
   - Definition 选 **Pipeline script from SCM**
   - SCM 选 **Git**
   - Repository URL：`https://github.com/yuxmgit/nginx-test-wsl.git`
     （或 SSH：`git@github.com:yuxmgit/nginx-test-wsl.git`）
   - Credentials：选 `github-ssh`（或 `github-credentials`）
   - Branch：`*/main`
   - Script Path：`Jenkinsfile`
4. 点 **Save**
5. 点 **Build Now** 试跑

### 8.1.1 关于"Jenkins 从哪拉代码"的常见误解

Jenkins **不会**去拉你 Windows 上的 `I:\练习\nginx`，也**不会**去拉 WSL 里的 `~/nginx-project`。
它只认一个地方：**GitHub 仓库**。

完整的数据流是这样的：

```
Windows I:\练习/nginx          ← 你在这里改代码
        │  git push
        ▼
github.com/yuxmgit/nginx-test-wsl.git
        │  git clone（由 Jenkins 执行）
        ▼
WSL: /var/lib/jenkins/workspace/nginx-deploy/   ← Jenkins 的临时工作区
        │  sudo bash deploy/ci-deploy.sh
        ▼
WSL: /home/yuxiangming/nginx-project/           ← 真正对外提供服务的位置
        │
        ▼
   nginx (:80) → 前端静态页 + 反代到 4001/4002
```

**所以第 3 章的 `git push` 是整个链路的起点。**
忘了 push，Jenkins 拉到的还是旧代码，部署完页面没变化 —— 这是新手最常踩的坑。

### 8.1.2 如果想在 WSL 里也有一份工作副本

纯粹是为了在 WSL 终端里方便看代码、跑测试，克隆一份到 `~/dev` 即可（不参与部署）：

```bash
mkdir -p ~/dev && cd ~/dev
git clone https://github.com/yuxmgit/nginx-test-wsl.git
```

### 8.2 多分支流水线（推荐，能自动发现分支和 PR）

`New Item` → 类型选 **Multibranch Pipeline**：

- **Branch Sources** → `GitHub` → 勾 **GitHub hook trigger for GITScm polling**
- Credentials 填 `github-credentials`（Token）
- Repository owner / name 填你的仓库
- `Scan Organization Triggers` 勾上，Interval 填 `1 H` 或 `5 min`

Webhook 触发时（见第 9 章）只有被推送的分支会跑构建。

---

## 第 9 章：配置 Webhook 实现推送即部署

### 9.1 GitHub 侧创建 Webhook

1. 打开仓库 → **Settings** → **Webhooks** → **Add webhook**
2. **Payload URL**：
   ```text
   http://localhost:8080/github-webhook/
   ```
   > ⚠️ `localhost` 是相对于 GitHub 服务器的！GitHub 在公网，访问不到你本机的 localhost。
   >
   > **解决办法（按环境选一个）：**
   > - **方案 1：隧道**（最省事）—— 用 ngrok：
   >   ```bash
   >   ngrok http 8080
   >   # 得到 https://xxxx.ngrok-free.app
   >   ```
   >   把这个地址填进 Payload URL，Content type 选 `application/json`。
   > - **方案 2：公网服务器** —— 把 Jenkins 部署到有公网 IP 的机器上。
   > - **方案 3：放弃 Webhook，用轮询**（见 9.3），完全不需要公网入口。
   > - **方案 4：GitHub Actions 触发 Jenkins** —— 见 9.4。
3. **Content type**：`application/json`
4. **Secret**：填一个随机串，比如 `myjenkinssecret2024`（勾上 SSL 验证也填这个）
5. **Which events** → 选 **Just the push event**
6. 点 **Add webhook**

### 9.2 Jenkins 侧接收 Webhook

安装 **GitHub plugin** 后，Jenkins 通常自动在 `http://localhost:8080/github-webhook/` 挂上端点。

如果 404，检查插件是否启用：`Manage Jenkins` → Plugins → Installed → 找 `GitHub plugin`。

### 9.3 方案：不用 Webhook，改用轮询（最省心，强烈建议先跑通这个）

**GitHub plugin** 提供的 **GitHub Hook trigger for GITScm polling** 本身支持轮询：
在多分支流水线里，`Scan Organization Triggers` 设为 `1 min`，Jenkins 会自己去查 GitHub 有没有新提交。

如果是单分支 Pipeline，用 **Poll SCM** 构建触发器：

`nginx-deploy` → **构建触发器** → 勾 **轮询 SCM** → 填：

```
H/2 * * * *
```

意思是每 2 分钟检查一次。语法是标准 cron 格式（分 时 日 月 周）。

### 9.4 方案：GitHub Actions 触发 Jenkins（保留 GitHub 原生 UI）

在仓库建 `.github/workflows/deploy.yml`：

```yaml
name: Trigger Jenkins Deploy

on:
  push:
    branches: [ main ]
  workflow_dispatch:

jobs:
  trigger:
    runs-on: ubuntu-latest
    steps:
      - name: Trigger Jenkins build
        run: |
          curl -X POST \
            -H "Authorization: Bearer ${{ secrets.JENKINS_TOKEN }}" \
            "${{ secrets.JENKINS_URL }}/job/nginx-deploy/buildWithParameters"
```

然后在 GitHub 仓库 **Settings** → **Secrets and variables** → **Actions** 里加两个 secret：

| Name | Value |
|---|---|
| `JENKINS_URL` | `http://你的Jenkins地址:8080` |
| `JENKINS_TOKEN` | Jenkins 用户的 API Token |

API Token 获取：Jenkins 右上角头像 → **Security** → **API Token** → **Generate new token**。

---

## 第 10 章：验证与排错

### 10.1 完整验证清单

```bash
# 1) GitHub 推送成功
git log --oneline -3

# 2) Jenkins 任务能拉到代码
#    在 Jenkins 任务里加一个临时步骤：pwd && ls -la && git log -1

# 3) 服务状态
systemctl status api-server1 api-server2 nginx

# 4) 端口
ss -tlnp | grep -E ':80|:4001|:4002'

# 5) 直连后端
curl -s http://127.0.0.1:4001/api/user; echo
curl -s http://127.0.0.1:4002/api/user; echo

# 6) 通过 Nginx
curl -s http://localhost/api/user; echo

# 7) 负载均衡是否交替
for i in $(seq 1 10); do
  curl -s http://localhost/api/user | grep -o '"server":"[^"]*"'
done

# 8) 前端页面
curl -s -o /dev/null -w '%{http_code}\n' http://localhost/
```

### 10.2 造一个"故障"验证回滚

故意改坏一个后端文件：

```bash
# 在编辑后的文件里写个语法错误
echo "const x = ;" >> backend/api-server1.js
git add . && git commit -m "test: 故意制造语法错误" && git push
```

预期结果：
1. Jenkins 构建触发
2. **阶段 3「部署前检查」** 就会挂掉，`node --check` 报语法错误
3. 线上服务**完全没被影响**（因为没走到部署阶段）

再测试"部署后健康检查失败"的回滚路径：写一个语法正确但启动即崩溃的代码，同样 push，观察 `ci-deploy.sh` 是否自动回滚到上一版。

### 10.3 常见报错对照表

| 报错 | 原因 | 解决 |
|---|---|---|
| `Permission denied (publickey)` | SSH 私钥没配到 Jenkins | 第 6.1 节，检查 `/var/lib/jenkins/.ssh/` 权限 |
| `fatal: could not read Username` | HTTPS 没配凭据 | 用 token 作密码，或改用 SSH |
| `Host key verification failed` | 首次连接未确认 host key | `sudo -u jenkins ssh -T git@github.com` 手动确认一次 |
| `sudo: a password is required` | 免密 sudo 没配 | 第 7 章，检查 `/etc/sudoers.d/jenkins` 权限 440 |
| `nginx: [emerg] invalid number of arguments` | nginx 配置语法错 | `sudo nginx -t` 看具体行号 |
| `500 Internal Server Error` | 后端进程挂了 | `journalctl -u api-server1 -n 50` |
| `502 Bad Gateway` | nginx 连不上后端 | 确认 4001/4002 端口在监听 |
| `Permission denied (publickey)` 在 `git push` 时 | Windows 侧没有 SSH 密钥 | Windows 也生成一份并加到 GitHub |
| Jenkins 构建卡在拉代码 | 网络问题 | 给 Jenkins 配代理，或改用内网 Git |
| `rejected (non-fast-forward)` | GitHub 仓库有初始 commit | `git pull --rebase origin main` 后再 push |
| Windows 提交后 WSL 里文件没变 | 路径不对 | WSL 里是 `/mnt/i/练习/nginx` |
| 端口 8080 被占 | 别的服务 | `sudo ss -tlnp \| grep 8080` |

---

## 附录 A：完整命令速查

### 你的实际路径速查

| 位置 | 路径 |
|---|---|
| Windows 项目目录 | `I:\练习\nginx` |
| WSL 里的项目目录 | `/mnt/i/练习/nginx` |
| WSL 部署产物目录 | `/home/yuxiangming/nginx-project` |
| Jenkins 工作区 | `/var/lib/jenkins/workspace/nginx-deploy` |
| Jenkins 初始密码文件 | `/var/lib/jenkins/secrets/initialAdminPassword` |
| GitHub 仓库 | `https://github.com/yuxmgit/nginx-test-wsl.git` |
| 备份目录 | `/home/yuxiangming/.deploy-backups/` |

```bash
# ===== WSL Ubuntu =====
# 服务管理
sudo systemctl restart api-server1 api-server2
sudo systemctl reload nginx
systemctl status api-server1 api-server2 nginx

# 日志
sudo journalctl -u api-server1 -f
sudo journalctl -u jenkins -f
sudo tail -f /var/log/nginx/error.log

# 手动触发一次部署（模拟 Jenkins，完全走同一套逻辑）
cd /mnt/i/练习/nginx
sudo bash deploy/ci-deploy.sh "$(pwd)" /home/yuxiangming/nginx-project

# 回滚到最近一次备份
ls -lt /home/yuxiangming/.deploy-backups/
sudo rsync -a --delete /home/yuxiangming/.deploy-backups/<时间戳>/backend/ /home/yuxiangming/nginx-project/backend/

# Jenkins 初始密码
sudo cat /var/lib/jenkins/secrets/initialAdminPassword

# ===== Windows Git Bash =====
cd /i/练习/nginx
git add .
git commit -m "..."
git push origin main
```

---

## 附录 A-1：最短路径行动清单（照着做就行）

如果你想快速跑通，按这个顺序：

| # | 在哪执行 | 命令 | 预期 |
|---|---|---|---|
| 1 | Windows | 启动代理软件（Clash / Verge / V2Ray 等） | — |
| 2 | Windows | `bash deploy/git-proxy-check.sh --set 7890` | 端口号按实际改；输出"仓库可达" |
| 3 | Windows | `git add . && git commit -m "ci: 接入 Jenkins" && git push -u origin main` | 推送成功 |
| 4 | WSL | `sudo bash deploy/jenkins-setup.sh` | 显示"Jenkins 环境准备完成" |
| 5 | WSL | `sudo cat /var/lib/jenkins/secrets/initialAdminPassword` | 拿到初始密码 |
| 6 | 浏览器 | 打开 `http://localhost:8080`，粘贴密码，装推荐插件 | 进入主界面 |
| 7 | 浏览器 | Manage Jenkins → System → PATH 填 `/usr/local/bin:/usr/bin:/bin` → 保存 | — |
| 8 | 浏览器 | Manage Jenkins → Credentials → 添加 SSH 私钥，ID 填 `github-ssh` | — |
| 9 | 浏览器 | New Item → Pipeline → SCM 填仓库地址 → Script Path 填 `Jenkinsfile` | — |
| 10 | 浏览器 | Build Now | 看到绿色 SUCCESS |
| 11 | 浏览器 | 打开 `http://localhost` | 页面正常，接口返回 JSON |
| 12 | Windows | 改一行前端文字 → `git push` | 1~2 分钟内 `http://localhost` 自动更新 |

第 12 步成功 = 自动化部署彻底跑通。

---

## 附录 A-2：三个必调的 Jenkinsfile 变量

打开 `Jenkinsfile` 顶部，按你的实际情况改：

```groovy
environment {
    DEPLOY_DIR   = '/home/yuxiangming/nginx-project'   // 部署目标目录
    DEPLOY_USER  = 'yuxiangming'                       // systemd service 的 User=
    GIT_REPO     = ''                                  // 留空 = 用 Jenkins 界面配置的 SCM
    GIT_BRANCH   = 'main'
}
```

改完记得 `git commit && git push`，否则 Jenkins 拉的还是旧的 Jenkinsfile。

---

## 附录 B：部署脚本行为说明

`deploy/ci-deploy.sh` 的 5 个阶段：

| 阶段 | 动作 | 失败处理 |
|---|---|---|
| 0 前置校验 | 检查源码结构、node、rsync 是否存在 | 立即退出 |
| 1 备份 | 旧版本复制到 `~/.deploy-backups/<时间戳>/`，只留 5 份 | 备份失败不阻断 |
| 2 同步 | rsync `--delete` 同步 backend/frontend | 立即退出 |
| 3 校验 | 检查 systemd unit 里的 node 路径是否还有效，失效则修正 | 自动修正 |
| 4 重启 | restart api-server1/2，`nginx -t` 通过才 reload | nginx -t 失败则不重载并退出 |
| 5 健康检查 | 4001/4002/nginx 各请求一次，全 200 才算成功 | **失败自动回滚**并退出码非 0 |

### 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `SKIP_BACKUP` | 0 | 设为 1 跳过备份 |
| `SKIP_RESTART` | 0 | 设为 1 只同步不重启（用于预热） |
| `HEALTH_RETRIES` | 10 | 健康检查重试次数 |
| `RUN_USER` | 当前用户 | systemd service 的 User= |

---

## 下一步可以做什么

1. **加测试**：在 Jenkins 阶段 3 加真实的接口断言，而不是只做语法检查
2. **加灰度**：部署到 4003 端口，验证通过再切 4001
3. **加数据库迁移**：如果后端接了 MySQL，迁移脚本放 `deploy/migrate.sql`，在阶段 4 前执行
4. **加多环境**：`environments { production { ... } staging { ... } }`
5. **迁移到云服务器**：WSL 方案跑通后，把 Jenkins 和应用都搬到云主机上，流程完全一样
