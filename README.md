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
│   ├── git-proxy-check.sh    # GitHub 连通性诊断 + 代理配置
│   ├── uninstall.sh          # 卸载清理
│   ├── lab-troubleshoot.sh   # 故障排查实验脚本
│   ├── README.md             # 部署指南
│   └── CI-CD部署指南.md      # GitHub + Jenkins 自动部署教程
├── Jenkinsfile               # Jenkins 声明式流水线
└── .gitignore
```

## 快速开始

### 人工部署（WSL Ubuntu）

```bash
cd /mnt/i/练习/nginx
bash deploy/deploy.sh
```

### 自动部署（推送到 GitHub 即触发）

```bash
git add .
git commit -m "feat: xxx"
git push origin main
```

Jenkins 会自动拉取代码、语法预检、rsync 同步、重启服务并做健康检查。
详见 [`deploy/CI-CD部署指南.md`](deploy/CI-CD部署指南.md)。

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
