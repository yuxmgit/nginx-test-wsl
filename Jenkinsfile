// ================================================================
// Nginx 负载均衡项目 —— Jenkins 声明式流水线
// 文件：Jenkinsfile（放在仓库根目录）
//
// 触发方式：
//   1. GitHub Webhook 推送触发（推荐，实时）
//   2. Jenkins 定时轮询（SCMSource）
//   3. 手动点击 "立即构建"
//
// 前提：Jenkins 运行在 WSL Ubuntu 内，部署目标也在同一台机器
// ================================================================

pipeline {
    agent any

    options {
        timestamps()                    // 每行日志带时间戳
        buildDiscarder(logRotator(numToKeepStr: '20'))  // 只保留 20 次构建
        disableConcurrentBuilds()      // 防止并发部署打架
        timeout(time: 10, unit: 'MINUTES')
    }

    environment {
        // ---------- 需要按你的实际情况修改的三个变量 ----------
        // 1) 目标部署目录
        DEPLOY_DIR   = '/home/yuxiangming/nginx-project'
        // 2) 部署用的系统用户（systemd service 里的 User=）
        DEPLOY_USER  = 'yuxiangming'
        // 3) 仓库地址（如果用 Webhook 触发，Jenkins 已自动 checkout，可留空）
        GIT_REPO     = ''
        GIT_BRANCH   = 'main'

        // 日志目录
        BUILD_TAG_SHORT = "${env.BUILD_NUMBER}"
    }

    stages {

        // ========== 阶段 1：拉代码 ==========
        stage('拉取代码') {
            steps {
                // 方式 A：用了 Webhook / 多分支流水线，这里会由 Jenkins 自动注入 SCM
                // 方式 B：单分支流水线且没配 SCM，则手动 checkout
                script {
                    if (env.GIT_COMMIT == null && env.GIT_REPO != '') {
                        checkout([
                            $class : 'GitSCM',
                            branches : [[name: "${env.GIT_BRANCH}"]],
                            userRemoteConfigs : [[
                                url: env.GIT_REPO,
                                credentialsId: 'github-credentials',
                                branch: "${env.GIT_BRANCH}"
                            ]],
                            extensions: [[
                                $class: 'CleanBeforeCheckout',
                                cleanBeforeCheckout: true
                            ]]
                        ])
                    }
                }
                sh 'echo "当前提交: ${GIT_COMMIT:-unknown}"'
                sh 'git log -1 --pretty=format:"%h %an %ad %s" || true'
                echo ""
            }
        }

        // ========== 阶段 2：环境检查 ==========
        stage('环境检查') {
            steps {
                sh '''
                    set -e
                    echo "--- Node ---"
                    node -v
                    npm -v
                    echo "--- Nginx ---"
                    nginx -v 2>&1 || true
                    echo "--- 端口占用 ---"
                    ss -tlnp 2>/dev/null | grep -E ':80|:4001|:4002' || echo "(尚未监听，属正常)"
                    echo "--- 部署目录权限 ---"
                    test -x "$(dirname "$DEPLOY_DIR")" || { echo "Jenkins 无法访问部署目录的父目录"; exit 1; }
                '''
            }
        }

        // ========== 阶段 3：语法检查（部署前先自查）============
        stage('部署前检查') {
            steps {
                sh '''
                    set -e
                    test -f backend/api-server1.js || { echo "缺少 api-server1.js"; exit 1; }
                    test -f backend/api-server2.js || { echo "缺少 api-server2.js"; exit 1; }
                    test -f frontend/index.html    || { echo "缺少 index.html"; exit 1; }
                    # Node 语法检查
                    node --check backend/api-server1.js
                    node --check backend/api-server2.js
                    echo "所有检查通过"
                '''
            }
        }

        // ========== 阶段 4：生成版本信息 ==========
        stage('生成版本信息') {
            steps {
                sh '''
                    set -e
                    # 版本号规则：v1.0.<构建号>，分支名也带进去便于区分环境
                    BRANCH_NAME="${BRANCH_NAME:-${GIT_BRANCH:-main}}"
                    VERSION="v1.0.${BUILD_NUMBER}-${BRANCH_NAME}"

                    bash deploy/gen-version.sh \
                        frontend/version.json \
                        "$VERSION" \
                        "${GIT_COMMIT:-unknown}" \
                        "$BRANCH_NAME" \
                        "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" \
                        "${BUILD_NUMBER}" \
                        "${BUILD_USER_ID:-jenkins}"
                '''
            }
        }

        // ========== 阶段 5：执行部署 ==========
        stage('执行部署') {
            steps {
                sh '''
                    set -e
                    RUN_USER="$DEPLOY_USER" bash deploy/ci-deploy.sh "$WORKSPACE" "$DEPLOY_DIR"
                '''
                sh '''
                    echo "===== 部署后状态 ====="
                    systemctl is-active api-server1 api-server2 nginx || true
                    echo "===== 负载均衡验证 ====="
                    for i in $(seq 1 6); do
                        printf "  第 %s 次 -> " "$i"
                        curl -s --max-time 5 http://localhost/api/user | grep -o '"server":"[^"]*"' || echo "请求失败"
                    done
                '''
            }
        }

        // ========== 阶段 6：冒烟测试 ==========
        stage('冒烟测试') {
            steps {
                sh '''
                    set -e
                    for url in http://localhost/ http://localhost/api/user http://localhost/api/products http://localhost/version.json; do
                        CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$url")
                        echo "$url -> $CODE"
                        [ "$CODE" = "200" ] || { echo "冒烟测试失败: $url"; exit 1; }
                    done
                    echo "冒烟测试全部通过"
                '''
                // 校验后端返回的版本与本次构建一致
                sh '''
                    set -e
                    echo "===== 版本一致性校验 ====="
                    FRONTEND_VERSION=$(curl -s --max-time 5 http://localhost/version.json | grep -o '"version":"[^"]*"' | cut -d'"' -f4)
                    echo "前端 version.json : $FRONTEND_VERSION"

                    BACKEND_VERSION=$(curl -s --max-time 5 http://localhost/api/version | grep -o '"version":"[^"]*"' | head -1 | cut -d'"' -f4)
                    echo "后端 /api/version : $BACKEND_VERSION"

                    [ -n "$FRONTEND_VERSION" ] || { echo "前端版本信息为空"; exit 1; }
                    [ "$FRONTEND_VERSION" = "$BACKEND_VERSION" ] || {
                        echo "版本不一致！前端=$FRONTEND_VERSION 后端=$BACKEND_VERSION"
                        exit 1
                    }
                    echo "版本一致：$FRONTEND_VERSION"
                '''
            }
        }
    }

    // ========== 构建后处理 ==========
    post {
        success {
            echo "构建 #${BUILD_NUMBER} 部署成功 ✅  提交: ${env.GIT_COMMIT ?: 'N/A'}"
        }
        failure {
            echo "构建 #${BUILD_NUMBER} 失败 ❌"
            sh '''
                echo "===== api-server1 最近日志 ====="
                sudo -n /usr/bin/journalctl -u api-server1 --no-pager --lines=40 || true
                echo "===== api-server2 最近日志 ====="
                sudo -n /usr/bin/journalctl -u api-server2 --no-pager --lines=40 || true
                echo "===== nginx 错误日志 ====="
                sudo -n /usr/bin/tail -n 30 /var/log/nginx/error.log || true
            '''.trim()
            // 可选：企业微信/钉钉/邮件通知
            // echo "部署失败，请检查 Jenkins 控制台日志"
        }
        always {
            cleanWs(cleanWhenNotBuilt: 'preserve')
        }
    }
}
