# Jenkins 自动触发配置指南

> 目标：`git push` → GitHub 收到推送 → Jenkins 自动拉代码 → 自动构建 → 自动部署
> 适用环境：Jenkins 跑在 WSL Ubuntu 内，仓库在 GitHub（`yuxmgit/nginx-test-wsl`）

---

## 一、先看清一个硬约束

你的 Jenkins 在 WSL 里，地址是 `172.18.32.10:8080` —— 这是 **WSL2 的 NAT 内网地址**。

```
GitHub 服务器 (公网)  ──✗──>  172.18.32.10:8080  (你的 WSL)
                              公网无法路由到 NAT 内网地址
```

这直接决定了两种触发方式的可行性：

| 方式 | 通信方向 | 你的环境可行？ |
|---|---|---|
| **Webhook**（GitHub 主动推） | GitHub → Jenkins | ❌ **需要公网入口**，GitHub 够不到你的 WSL |
| **Poll SCM**（Jenkins 主动查） | Jenkins → GitHub | ✅ **完全可行**，Jenkins 出站不受 NAT 影响 |

> 这就是为什么网上很多教程让你"在 GitHub 添加 Webhook"之后发现根本没反应 —— 根本不是配置错了，
> 而是 GitHub 的请求压根到不了你的机器。

所以我给出三个方案，按推荐度排序。

---

## 二、方案对比

| | 方案 A：Poll SCM | 方案 B：ngrok 隧道 | 方案 C：自托管 Runner |
|---|---|---|---|
| **触发延迟** | 等轮询间隔（1~2 分钟） | **秒级** | **秒级** |
| **需要公网** | 否 | 是（隧道提供） | 否 |
| **需要额外装东西** | 无 | ngrok | GitHub Actions Runner |
| **配置复杂度** | ⭐ 最低 | ⭐⭐⭐ | ⭐⭐⭐ |
| **稳定性** | ⭐⭐⭐ 高 | ⭐⭐ 隧道断了就断 | ⭐⭐⭐ 高 |
| **适合场景** | **学习 / 内网 / 演示** | 临时演示、对外展示 | 想用 GitHub 原生界面 |
| **代价** | 有延迟 | 隧道 URL 每次变，要改 webhook | 多一个 runner 进程要维护 |

**我的建议：先用方案 A 跑通**（5 分钟，零风险），确认整条链路没问题后，
再按需升级到 B 或 C。学习阶段没必要一开始就上隧道。

---

## 三、方案 A：Poll SCM（推荐先做这个）

### 3.1 配置步骤

1. 打开 Jenkins → 点进你的任务 `nginx-deploy`
2. 左侧 **Configure**（配置）
3. 找到 **Build Triggers**（构建触发器）区域
4. 勾选 **Poll SCM**（轮询 SCM）
5. 填入轮询表达式：

```
H/2 * * * *
```

6. 点 **保存**

### 3.2 轮询表达式怎么读

用的是标准 cron 格式（分 时 日 月 周），`H` 表示"由 Jenkins 随机哈希分配"（错开多任务的触发时刻，避免同时打满 GitHub）。

| 表达式 | 含义 |
|---|---|
| `H/2 * * * *` | 每 2 分钟（推荐） |
| `H/5 * * * *` | 每 5 分钟（更省资源） |
| `H * * * *` | 每小时 |
| `H 2 * * *` | 每天凌晨 2 点 |
| `H/1 * * * *` | 每分钟（调试用，压力大） |

> 调试时可以先用 `H/1 * * * *`，确认能触发后再放宽到 `H/2` 或 `H/5`。

### 3.3 前提条件（这三点缺一不可）

**① 任务必须配置了 SCM**

Configure → **Pipeline** 区域：

| 字段 | 值 |
|---|---|
| Definition | `Pipeline script from SCM` |
| SCM | `Git` |
| Repository URL | `git@github.com:yuxmgit/nginx-test-wsl.git` |
| Credentials | 选你的 SSH 凭据 |
| Branch | `*/main` ← **必须是 main，不是 master** |
| Script Path | `Jenkinsfile` |

> ⚠️ **Branch 写错是最常见的坑**。你早期提交用的是 master，后来才改成 main。
> 如果这里还写着 `*/master`，推 main 永远不会触发构建。

**② Jenkins 必须能访问 GitHub**

```bash
# WSL 里执行
curl -sI --max-time 10 https://github.com | head -1
```

如果超时，说明 WSL 里没配代理。Windows 的代理**不会自动给 WSL 用**，需要在 WSL 里单独配：

```bash
# 获取 Windows 主机 IP
WIN_HOST=$(ip route show default | awk '{print $3}')

# 写入 ~/.bashrc
cat >> ~/.bashrc << EOF
export http_proxy=http://${WIN_HOST}:7890
export https_proxy=http://${WIN_HOST}:7890
export no_proxy=localhost,127.0.0.1
EOF

# apt 也需要单独配
sudo tee /etc/apt/apt.conf.d/99proxy > /dev/null << EOF
Acquire::http::Proxy "http://${WIN_HOST}:7890";
Acquire::https::Proxy "http://${WIN_HOST}:7890";
EOF

source ~/.bashrc
curl -sI --max-time 10 https://github.com | head -1
```

> 端口 7890 换成你代理软件的实际端口。

**③ 凭据必须可用**

```bash
# 验证 jenkins 用户的 SSH 密钥能连上 GitHub
sudo -u jenkins ssh -T git@github.com
# 期望输出: Hi yuxmgit! You've successfully authenticated...
```

### 3.4 验证

```bash
# Windows 上
cd /i/练习/nginx
echo "# 触发测试" >> README.md
git add . && git commit -m "test: 验证自动触发" && git push origin main
```

然后：

- 等 1~2 分钟
- 打开 Jenkins 任务页，**Build History** 里应该出现新的构建号
- 点进去看 **Changes**，能看到你刚才那个 commit
- 打开 `http://localhost`，版本面板的构建号应该变了

### 3.5 排错

| 现象 | 原因 | 解决 |
|---|---|---|
| 完全没有新构建 | Branch 配错（`*/master`） | 改成 `*/main` |
| 构建了但拉代码失败 | Jenkins 访问不了 GitHub | 见 3.3 ② 配代理 |
| 构建了但拉代码 Permission denied | 凭据不对 | 检查 SSH 私钥是否在 `/var/lib/jenkins/.ssh/` |
| 构建了但拉的是旧代码 | 缓存 | Build History → 该构建 → 重新构建 |
| 轮询不生效 | 任务不在 SCM 模式 | Definition 必须选 `Pipeline script from SCM` |

**查 Jenkins 侧日志**：

```bash
sudo journalctl -u jenkins -f | grep -iE "polling|SCM|poll"
```

**开 GitHub 插件的调试日志**（更详细）：

Manage Jenkins → System → **Add log recorder** → 记录器名填 `github-debug`，
勾选 `com.cloudbees.jenkins.GitHubPushTrigger`、`org.jenkinsci.plugins.github.webhook.WebhookManager`。
然后在 System Log 里选这个记录器查看。

---

## 四、方案 B：ngrok 隧道 + 真 Webhook（秒级触发）

### 4.1 原理

ngrok 在你的机器上开一个公网可访问的隧道，把公网请求转发到本地的 `localhost:8080`：

```
git push → GitHub → POST https://xxx.ngrok.io/github-webhook/ → 你的 WSL Jenkins
```

### 4.2 步骤

**① 装 ngrok**

```bash
# WSL 里
sudo apt install -y snapd
sudo snap install ngrok
ngrok config add-authtoken <你的ngrok_auth_token>   # 在 ngrok.com 注册后拿到
```

**② 开隧道**

```bash
ngrok http 8080
```

会输出：

```
Forwarding  https://a1b2c3d4.ngrok-free.app -> http://localhost:8080
```

**③ Jenkins 侧配置**

Manage Jenkins → System → **GitHub** 区域：

| 字段 | 值 |
|---|---|
| GitHub API URL | `https://api.github.com`（默认） |
| Hook URL | `https://a1b2c3d4.ngrok-free.app/github-webhook/` |
| Credentials | 选你的 token 凭据 |

任务 Configure → **Build Triggers** → 勾选 **GitHub hook trigger for GITScm polling**。

**④ GitHub 侧配置**

仓库 → Settings → Webhooks → Add webhook：

| 字段 | 值 |
|---|---|
| Payload URL | `https://a1b2c3d4.ngrok-free.app/github-webhook/` ← **末尾斜杠必须有** |
| Content type | `application/json` |
| Secret | 随便设一个，如 `mysecret123` |
| Which events | **Just the push event** |

**⑤ 测试**

在 GitHub webhook 页面点 **Recent Deliveries** → 应该看到 `Response 200 OK`。

### 4.3 三个必踩的坑

1. **Payload URL 末尾斜杠不能少**。Jenkins 端点是 `/github-webhook/`，少了斜杠就是 404。
2. **ngrok URL 每次重启都变**。隧道一断，webhook 就失效了。免费版可以申请固定域名：
   ```bash
   # 在 ngrok.com 后台 → Domains → 创建一个固定域名
   ngrok http 8080 --domain=你的固定域名.ngrok-free.app
   ```
3. **安全**：隧道把 Jenkins 暴露到公网了。建议同时：
   - Manage Jenkins → Security → CSRF Protection → 勾 **Enable proxy compatibility**
   - Jenkins 里关掉匿名访问
   - 定期重启隧道

### 4.4 什么时候用

- 想看到**秒级**触发效果
- 演示给别人看"push 完立刻就部署了"
- **不建议**长期用：隧道稳定性依赖第三方，URL 变动是持续的麻烦

---

## 五、方案 C：GitHub Actions + 自托管 Runner（秒级且无需公网）

### 5.1 原理

在 WSL 里注册一个 GitHub Actions Runner。Runner 常驻本机，
GitHub 有新 push 时把任务派发给它，Runner 再调 Jenkins 的 API 触发构建。

```
git push → GitHub → 派发任务给本机 Runner → Runner 调 Jenkins API → 构建
                    ↑ 全部在本机闭环，不需要公网入口
```

### 5.2 步骤

**① 拿 Runner**

仓库 → Settings → **Actions** → **Runners** → **New self-hosted runner**
→ 选 Linux / x64 → 复制下载命令。

**② 在 WSL 里安装并注册**

```bash
mkdir -p ~/actions-runner && cd ~/actions-runner
# 按 GitHub 页面给的命令下载解压
./config.sh --url https://github.com/yuxmgit/nginx-test-wsl \
            --token <页面给的一次性注册 token>
./run.sh
```

**③ 配成后台服务**（可选，让它开机自启）

```bash
sudo ./svc.sh install
sudo ./svc.sh start
sudo ./svc.sh status
```

**④ 建 workflow**

仓库新建 `.github/workflows/trigger-jenkins.yml`：

```yaml
name: Trigger Jenkins

on:
  push:
    branches: [ main ]
  workflow_dispatch:

jobs:
  trigger:
    runs-on: [ self-hosted, linux ]
    steps:
      - name: Call Jenkins build API
        run: |
          curl -X POST \
            -H "Authorization: Bearer ${{ secrets.JENKINS_TOKEN }}" \
            "${{ secrets.JENKINS_URL }}/job/nginx-deploy/build"
```

**⑤ 加 GitHub Secret**

仓库 → Settings → Secrets and variables → Actions → New repository secret：

| Name | Value |
|---|---|
| `JENKINS_URL` | `http://localhost:8080` |
| `JENKINS_TOKEN` | Jenkins API Token |

> Runner 跑在本机，所以 `localhost:8080` 就够了，不用隧道。
> 这里的 `JENKINS_TOKEN` 是 **Jenkins 的 API Token**（不是 GitHub 的）：
> Jenkins 右上角头像 → Security → API Token → Generate new token。

### 5.3 注意

- Runner 会以当前用户身份运行，**记得它能 SSH 到 GitHub**（否则 checkout 不了）
- `runs-on: [self-hosted, linux]` 的标签要和注册时一致
- Runner 是常驻进程，WSL 重启后要重新起（配 `svc.sh` 可解决）

---

## 六、方案 D：Jenkins 侧主动轮询 GitHub API（最轻量）

不依赖任何插件，只用 Jenkins 的 Pipeline + GitHub API + cron。

在 Jenkinsfile 里加一个定时检查的阶段：

```groovy
pipeline {
    agent any
    triggers {
        cron('H/2 * * * *')       // 每 2 分钟检查一次
    }
    stages {
        stage('拉取代码') {
            steps {
                checkout scm
            }
        }
        // ... 其余阶段
    }
}
```

配合 `triggers { cron(...) }`，效果接近 Poll SCM。区别是 Poll SCM 在
**git 插件层面**比较 commit hash，没变化就不构建；而 cron 触发每次都会走完整流水线，
浪费资源。**所以优先用 Poll SCM，而不是 cron + checkout。**

---

## 七、怎么验证整条链路真的通了

### 7.1 端到端验证脚本

```bash
# WSL 里
bash deploy/jenkins-diagnose.sh
```

这个脚本会依次检查：Jenkins 服务状态 → 任务是否存在 → 触发器配置 →
Jenkins→GitHub 连通性 → webhook 状态，并指出该用哪个方案。

带 `--trigger` 参数还会实际触发一次构建。

### 7.2 完整链路验证（最有说服力）

```bash
# 1. 记下当前版本
curl -s http://localhost/version.json | grep version

# 2. 改一行前端
#    编辑 frontend/index.html，随便改个字

# 3. 提交推送
git add . && git commit -m "feat: 验证自动触发" && git push origin main

# 4. 等 1~2 分钟（Jenkins 轮询到新提交）

# 5. 再看版本，应该是新的构建号
curl -s http://localhost/version.json | grep version
```

**两个版本号不同 = 整条链路完全打通。**

### 7.3 逐段确认

| 环节 | 确认方法 |
|---|---|
| GitHub 收到推送 | 仓库首页能看到新 commit |
| Jenkins 发现新提交 | 任务页 Build History 出现新构建 |
| Jenkins 拉到正确代码 | 构建日志里 `git log -1` 显示你的 commit message |
| 部署成功 | 构建日志阶段 5 无报错 |
| 线上生效 | `curl localhost/version.json` 版本号变了 |
| 页面生效 | 浏览器刷新 `http://localhost`，版本面板更新 |

---

## 八、我的建议

按这个顺序来：

1. **先跑诊断脚本**：`bash deploy/jenkins-diagnose.sh` —— 看清现状
2. **配置方案 A**（Poll SCM，`H/2 * * * *`）—— 5 分钟搞定，先确认链路通
3. **做一次端到端验证** —— 改代码 → push → 等 → 刷新页面看到新版本号
4. **如果觉得 2 分钟延迟难受**，再上方案 C（自托管 Runner）

**不建议**现在就用 ngrok：URL 每次变会持续制造麻烦，而你现在的核心诉求是
"体验完整的 CI/CD 流程"，延迟 1~2 分钟完全不影响体验。

---

## 九、常见问题速查

| 问题 | 原因 | 解决 |
|---|---|---|
| GitHub webhook 显示 200 但 Jenkins 没构建 | Jenkins 侧没勾 GitHub trigger | 两边都要配，缺一不可 |
| Webhook 显示 503/超时 | GitHub 够不到你的 Jenkins | 用方案 A 或 C |
| Poll SCM 不触发 | Branch 配的是 `*/master` | 改成 `*/main` |
| Poll SCM 触发但拉代码失败 | WSL 没配代理 | 见 3.3 ② |
| 构建卡在拉代码 | SSH 凭据失效 | `sudo -u jenkins ssh -T git@github.com` 验证 |
| 触发器勾了没生效 | Definition 不是 SCM 模式 | 必须选 `Pipeline script from SCM` |
| 每次都触发但内容没变 | 用了 cron 而非 Poll SCM | 换回 Poll SCM |
| 部署成功但页面没变 | 浏览器缓存 | Ctrl+F5 强刷（version.json 已加时间戳绕缓存） |
