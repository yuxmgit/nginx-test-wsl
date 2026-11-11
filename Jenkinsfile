// ================================================================
// Nginx 负载均衡项目 —— Jenkins 声明式流水线
// 文件：Jenkinsfile（放在仓库根目录）
//
// 触发方式：
//   1. GitHub Webhook 推送触发（推荐，实时）
//   2. Jenkins 定时轮询（SCMSource）
//   3. 手动点击 "立即构建"
//
// 前提：Jenkins 运行在 WSL Ubuntu 内
//   模式一（默认）：部署目标也在本机
//   模式二（多机）  ：通过 SSH 推送到另一台 Ubuntu，见 REMOTE_* 变量
// ================================================================

pipeline {
    agent any

    parameters {
        // 多机部署开关：勾选后额外执行「远程部署」阶段
        booleanParam(
            name: 'REMOTE_DEPLOY',
            defaultValue: false,
            description: '是否部署到远程 Ubuntu（需要 deploy/inventory.ini）')
        // 要部署的主机 ID，逗号分隔；留空表示 inventory 中全部启用的主机
        string(
            name: 'TARGET_HOSTS',
            defaultValue: '',
            description: '目标主机 ID，如 web-01,web-02；留空=全部')
        // 演练模式：只打印计划不实际执行
        booleanParam(
            name: 'DRY_RUN',
            defaultValue: false,
            description: '演练模式（只打印执行计划，不真正部署）')
    }

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

        // ---------- 多机部署相关 ----------
        // 主机清单（仓库内维护，每台机器一个 [节]）
        INVENTORY_FILE  = 'deploy/inventory.ini'
        // SSH 私钥路径（由 Jenkins 凭据或 jenkins-setup.sh 安装）
        SSH_KEY_FILE    = '/var/lib/jenkins/.ssh/deploy_key'
        // 显式注入参数到 shell 环境，保证 sh 步骤能读到
        REMOTE_DEPLOY   = "${params.REMOTE_DEPLOY}"
        DRY_RUN         = "${params.DRY_RUN}"
        TARGET_HOSTS    = "${params.TARGET_HOSTS}"
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
                script {
                    if (params.REMOTE_DEPLOY) {
                        echo ">>> 模式：多机远程部署（Push over SSH）"
                    } else {
                        echo ">>> 模式：本机部署"
                    }
                }
                sh '''
                    set -e
                    if [ "${REMOTE_DEPLOY}" = "true" ]; then
                        # TARGET_HOSTS 是逗号分隔的，脚本按位置参数接收，需转成空格分隔
                        HOSTS="$(echo "${TARGET_HOSTS}" | tr ',' ' ')"
                        echo "目标主机列表：${HOSTS:-（inventory 中全部启用的主机）}"
                        DRY_RUN="${DRY_RUN}" bash deploy/remote-deploy.sh "$WORKSPACE" "$INVENTORY_FILE" $HOSTS
                    else
                        RUN_USER="$DEPLOY_USER" bash deploy/ci-deploy.sh "$WORKSPACE" "$DEPLOY_DIR"
                    fi
                '''
                sh '''
                    echo "===== 部署后状态 ====="
                    if [ "${REMOTE_DEPLOY}" = "true" ]; then
                        echo "（远端状态见上方各主机部署日志）"
                    else
                        systemctl is-active api-server1 api-server2 nginx || true
                        echo "===== 负载均衡验证 ====="
                        for i in $(seq 1 6); do
                            printf "  第 %s 次 -> " "$i"
                            curl -s --max-time 5 http://localhost/api/user | grep -o '"server":"[^"]*"' || echo "请求失败"
                        done
                    fi
                '''
            }
        }

        // ========== 阶段 6：冒烟测试 ==========
        stage('冒烟测试') {
            steps {
                script {
                    if (params.REMOTE_DEPLOY) {
                        // 多机模式：本机无服务，冒烟测试改到各目标机上执行
                        echo ">>> 多机模式：在各目标机上执行冒烟测试"
                        def ids = params.TARGET_HOSTS?.split(',')?.findAll { it.trim() } ?: []
                        if (ids.isEmpty()) {
                            // 未指定主机，则从 inventory 中解析全部启用的主机
                            def inv = readFile(file: "${env.WORKSPACE}/deploy/inventory.ini")
                            ids = []
                            inv.eachLine { line ->
                                def t = line.replaceAll(/#.*/, '').trim()
                                if (t.startsWith('[') && t.endsWith(']')) {
                                    ids << t[1..-2]
                                }
                            }
                        }
                        echo "目标主机：${ids.join(', ')}"

                        ids.each { hid ->
                            stage("冒烟-${hid}") {
                                sh """
                                    set -euo pipefail
                                    SSH_KEY_FILE='${env.SSH_KEY_FILE}'
                                    SSH_OPTS="-i \$SSH_KEY_FILE -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes"

                                    # 从 inventory 读取该主机信息
                                    inv_get() {
                                        awk -v id='${hid}' -v key="\$1" '
                                            /^\\[/ { cur = substr(\$0, 2, length(\$0)-2) }
                                            cur == id && \$0 ~ "^[[:space:]]*"key"[[:space:]]*=" {
                                                line = \$0
                                                sub(/^[^=]*=[[:space:]]*/, "", line)
                                                gsub(/[[:space:]]/, "", line)
                                                print line; exit
                                            }' deploy/inventory.ini
                                    }

                                    HOST_RAW="\$(inv_get host)"
                                    SSH_USER="\$(inv_get ssh_user)"
                                    PORT="\$(inv_get health_port)"
                                    [ -n "\$HOST_RAW" ] || { echo "inventory 中找不到主机 ${hid}"; exit 1; }
                                    PORT="\${PORT:-80}"

                                    # host 支持 wsl:<发行版名> 语法：动态解析真实 IP
                                    # （WSL 是 NAT 网络，发行版 IP 每次重启都会变）
                                    if [[ "\$HOST_RAW" == wsl:* ]]; then
                                        DISTRO="\${HOST_RAW#wsl:}"
                                        WSL_EXE="/mnt/c/Windows/System32/wsl.exe"
                                        HOST=\$("\$WSL_EXE" -d "\$DISTRO" -- hostname -I 2>/dev/null | awk '{print \$1}')
                                        [ -n "\$HOST" ] || { echo "无法解析 \$HOST_RAW"; exit 1; }
                                        echo "解析 \$HOST_RAW -> \$HOST"
                                    else
                                        HOST="\$HOST_RAW"
                                    fi

                                    TARGET="\${SSH_USER}@\${HOST}"
                                    echo "目标：\$TARGET  端口：\$PORT"

                                    for url in "http://127.0.0.1:\$PORT/" "http://127.0.0.1:\$PORT/api/user" "http://127.0.0.1:\$PORT/version.json"; do
                                        CODE=\$(ssh \$SSH_OPTS "\$TARGET" "curl -s -o /dev/null -w '%{http_code}' --max-time 5 \$url" 2>/dev/null || echo 000)
                                        echo "  \$url -> \$CODE"
                                        [ "\$CODE" = "200" ] || { echo "冒烟测试失败: \$url"; exit 1; }
                                    done

                                    # 远端前后端版本一致性校验
                                    FV=\$(ssh \$SSH_OPTS "\$TARGET" "curl -fsS --max-time 5 http://127.0.0.1:\$PORT/version.json" | node -e '
                                        let b=""; process.stdin.setEncoding("utf8");
                                        process.stdin.on("data", c => b += c);
                                        process.stdin.on("end", () => {
                                            const i = JSON.parse(b);
                                            if (!i.version) process.exit(1);
                                            process.stdout.write(i.version);
                                        });
                                    ')
                                    BV=\$(ssh \$SSH_OPTS "\$TARGET" "curl -fsS --max-time 5 http://127.0.0.1:\$PORT/api/version" | node -e '
                                        let b=""; process.stdin.setEncoding("utf8");
                                        process.stdin.on("data", c => b += c);
                                        process.stdin.on("end", () => {
                                            const r = JSON.parse(b);
                                            const v = r.data && r.data.version;
                                            if (!v) process.exit(1);
                                            process.stdout.write(v);
                                        });
                                    ')
                                    echo "  前端版本: \$FV"
                                    echo "  后端版本: \$BV"
                                    [ "\$FV" = "\$BV" ] || { echo "  版本不一致！"; exit 1; }
                                    echo "  ✓ ${hid} 冒烟测试通过，版本一致：\$FV"
                                """
                            }
                        }
                    } else {
                        // 本机模式：原有逻辑
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
                            set -euo pipefail
                            echo "===== 版本一致性校验 ====="
                            FRONTEND_VERSION=$(curl -fsS --max-time 5 http://localhost/version.json | node -e '
                                let body = "";
                                process.stdin.setEncoding("utf8");
                                process.stdin.on("data", chunk => body += chunk);
                                process.stdin.on("end", () => {
                                    const info = JSON.parse(body);
                                    if (typeof info.version !== "string" || !info.version) process.exit(1);
                                    process.stdout.write(info.version);
                                });
                            ')
                            echo "前端 version.json : $FRONTEND_VERSION"

                            BACKEND_VERSION=$(curl -fsS --max-time 5 http://localhost/api/version | node -e '
                                let body = "";
                                process.stdin.setEncoding("utf8");
                                process.stdin.on("data", chunk => body += chunk);
                                process.stdin.on("end", () => {
                                    const response = JSON.parse(body);
                                    const version = response.data && response.data.version;
                                    if (typeof version !== "string" || !version) process.exit(1);
                                    process.stdout.write(version);
                                });
                            ')
                            echo "后端 /api/version : $BACKEND_VERSION"

                            [ "$FRONTEND_VERSION" = "$BACKEND_VERSION" ] || {
                                echo "版本不一致！前端=$FRONTEND_VERSION 后端=$BACKEND_VERSION"
                                exit 1
                            }
                            echo "版本一致：$FRONTEND_VERSION"
                        '''
                    }
                }
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
            script {
                if (params.REMOTE_DEPLOY) {
                    // 多机模式：拉取目标机日志
                    sh '''
                        echo "===== 远端日志 ====="
                        SSH_KEY_FILE="${SSH_KEY_FILE}"
                        SSH_OPTS="-i $SSH_KEY_FILE -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes"
                        for id in $(awk '/^\\[/ {gsub(/[][]/,""); print}' deploy/inventory.ini); do
                            inv_get() {
                                awk -v id="$id" -v key="$1" '
                                    /^\\[/ { cur = substr($0, 2, length($0)-2) }
                                    cur == id && $0 ~ "^[[:space:]]*"key"[[:space:]]*=" {
                                        line = $0
                                        sub(/^[^=]*=[[:space:]]*/, "", line)
                                        gsub(/[[:space:]]/, "", line)
                                        print line; exit
                                    }' deploy/inventory.ini
                            }
                            HOST_RAW=$(inv_get host)
                            USR=$(inv_get ssh_user)
                            [ -n "$HOST_RAW" ] || continue
                            # host 支持 wsl:<发行版名> 语法
                            if [[ "$HOST_RAW" == wsl:* ]]; then
                                DISTRO="${HOST_RAW#wsl:}"
                                HOST=$(/mnt/c/Windows/System32/wsl.exe -d "$DISTRO" -- hostname -I 2>/dev/null | awk '{print $1}')
                            else
                                HOST="$HOST_RAW"
                            fi
                            [ -n "$HOST" ] || continue
                            echo "--- $id ($USR@$HOST) ---"
                            ssh $SSH_OPTS "$USR@$HOST" "sudo -n /usr/bin/journalctl -u api-server1 --no-pager --lines=30 2>/dev/null || true; sudo -n /usr/bin/journalctl -u api-server2 --no-pager --lines=30 2>/dev/null || true; sudo -n /usr/bin/tail -n 30 /var/log/nginx/error.log 2>/dev/null || true" 2>&1 || echo "（无法连接 $id）"
                        done
                    '''.trim()
                } else {
                    sh '''
                        echo "===== api-server1 最近日志 ====="
                        sudo -n /usr/bin/journalctl -u api-server1 --no-pager --lines=40 || true
                        echo "===== api-server2 最近日志 ====="
                        sudo -n /usr/bin/journalctl -u api-server2 --no-pager --lines=40 || true
                        echo "===== nginx 错误日志 ====="
                        sudo -n /usr/bin/tail -n 30 /var/log/nginx/error.log || true
                    '''.trim()
                }
            }
            // 可选：企业微信/钉钉/邮件通知
            // echo "部署失败，请检查 Jenkins 控制台日志"
        }
        always {
            cleanWs(cleanWhenNotBuilt: 'preserve')
        }
    }
}
