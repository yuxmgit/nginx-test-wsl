# nginx-test-wsl

Nginx 负载均衡练习项目 —— 前端静态页 + 双 Node 后端（4001 / 4002），部署在 WSL Ubuntu。

## 项目结构

```
nginx-test-wsl/
├── backend/
│   ├── api-server1.js        # API 服务器 A，监听 4001
│   └── api-server2.js        # API 服务器 B，监听 4002
├── frontend/
│   ├── index.html            # 前端页面，通过 /api/ 反向代理访问后端
│   ├── version.json          # 部署版本信息（构建时生成，不入库）
│   └── version.json.template # 版本信息模板（手动部署时兜底）
├── deploy/
│   ├── deploy.sh             # 人工一键部署（首次安装 nginx / systemd）
│   ├── ci-deploy.sh          # CI 无人值守部署（失败自动回滚）
│   ├── gen-version.sh        # 生成 version.json（构建信息注入）
│   ├── jenkins-setup.sh      # Jenkins 一键安装 + 免密 sudo
│   ├── jenkins-diagnose.sh   # 自动触发链路诊断
│   ├── git-proxy-check.sh    # GitHub 连通性诊断 + 代理配置
│   ├── uninstall.sh          # 卸载清理
│   ├── lab-troubleshoot.sh   # 故障排查实验脚本
│   ├── README.md             # 部署指南
│   ├── CI-CD部署指南.md      # GitHub + Jenkins 自动部署教程
│   └── jenkins-auto-trigger.md  # 自动触发配置（Poll SCM / ngrok / Runner）
├── Jenkinsfile               # Jenkins 声明式流水线
└── .gitignore
```

## 快速开始

### 人工部署（WSL Ubuntu）

```bash
cd /mnt/i/练习/nginx
bash deploy/deploy.sh
```

### 自动部署（Git 提交 → Jenkins 构建 → WSL 部署）

```bash
git status
# 将路径替换为本次改动的文件，例如 git add frontend/index.html
git add frontend/index.html
git diff --cached
git commit -m "feat: 描述本次改动"
git push origin main
```

推送到 `main` 后，Jenkins 按任务中配置的触发方式启动构建。整条流水线如下：

1. GitHub 保存新提交；Webhook 可用时由推送通知 Jenkins，否则由 Poll SCM 轮询发现提交。
2. Jenkins 从 `main` 检出代码，检查 Node/Nginx/部署目录和后端 JavaScript 语法。
3. Jenkins 生成带构建号、分支和 commit SHA 的 `frontend/version.json`。
4. `deploy/ci-deploy.sh` 备份当前版本，并用 `rsync` 同步前后端文件到 WSL 部署目录。
5. 重启两个 Node 服务、检查并重载 Nginx；健康检查失败时尝试恢复备份版本。
6. Jenkins 对首页、API、版本文件做冒烟测试，并检查前后端版本一致。

构建通过后打开 <http://localhost> 查看部署信息面板；页面显示的 commit 和构建号应对应本次提交。
详细的日常操作、流水线阶段和排错步骤见 [`deploy/CI-CD部署指南.md`](deploy/CI-CD部署指南.md)；
触发器配置见 [`deploy/jenkins-auto-trigger.md`](deploy/jenkins-auto-trigger.md)。

**诊断当前触发链路**：

```bash
# WSL Ubuntu 里
bash deploy/jenkins-diagnose.sh
```

完整教程见 [`deploy/CI-CD部署指南.md`](deploy/CI-CD部署指南.md)。

## 访问地址

- 前端页面：<http://localhost>
- 接口示例：<http://localhost/api/user>、<http://localhost/api/products>
- 版本查询：<http://localhost/api/version>、<http://localhost/version.json>

## 部署信息面板

首页顶部的绿色面板显示当前线上跑的是哪一次构建：

| 字段 | 来源 |
|---|---|
| 版本号 | `v1.0.<构建号>-<分支>`，由 Jenkins 生成 |
| Git Commit | 本次构建的 commit SHA |
| 分支 | 触发构建的分支 |
| 构建号 | Jenkins `BUILD_NUMBER` |
| 构建时间 | 构建时刻（UTC） |
| 构建者 | 触发构建的 Jenkins 用户 |

数据来自部署时由 Jenkins 写入的 `frontend/version.json`。
**每次 `git push` 后，刷新页面就能看到版本号和 Commit 变化** —— 这是验证 CI/CD 链路是否真正跑通的最直接方式。

后端也提供 `/api/version` 接口，页面会对比前后端版本是否一致（不一致会标红）。

## 常用运维命令

| 需求 | 命令 |
|---|---|
| 查看后端状态 | `systemctl status api-server1 api-server2` |
| 实时看日志 | `journalctl -u api-server1 -f` |
| 重启后端 | `sudo systemctl restart api-server1 api-server2` |
| 改完 Nginx 配置 | `sudo nginx -t && sudo systemctl reload nginx` |
| 端口占用 | `ss -tlnp \| grep -E ':80\|:4001\|:4002'` |
| 负载均衡验证 | `for i in $(seq 1 10); do curl -s http://localhost/api/user \| grep -o '"server":"[^"]*"'; done` |
