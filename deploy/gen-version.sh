#!/bin/bash
#
# 生成部署版本信息文件
#
# 用途：Jenkins 部署前调用，把本次构建的元信息写成 version.json，
#       前端页面读取它来展示"当前线上跑的是哪一次构建"。
#
# 用法：
#   bash deploy/gen-version.sh <输出文件> [version] [commit] [branch] [buildTime] [buildNumber] [builtBy]
#
# 全部参数都有默认值，环境变量优先：
#   BUILD_VERSION / GIT_COMMIT / BRANCH_NAME / BUILD_NUMBER / BUILD_USER_ID
#
# 示例：
#   BUILD_NUMBER=42 GIT_COMMIT=abc123 bash deploy/gen-version.sh frontend/version.json
#
set -euo pipefail

OUT_FILE="${1:-frontend/version.json}"

VERSION="${2:-${BUILD_VERSION:-v1.0.0-dev}}"
COMMIT="${3:-${GIT_COMMIT:-unknown}}"
BRANCH="${4:-${BRANCH_NAME:-${GIT_BRANCH:-main}}}"
BUILD_TIME="${5:-$(date -u '+%Y-%m-%d %H:%M:%S UTC')}"
BUILD_NO="${6:-${BUILD_NUMBER:-local}}"
BUILT_BY="${7:-${BUILD_USER_ID:-local}}"

# 短 commit 便于页面展示
SHORT_COMMIT="$(printf '%s' "$COMMIT" | cut -c1-7)"

# 本地没跑在 git 仓库里时，尝试自己取一次
if [ "$COMMIT" = "unknown" ] && command -v git >/dev/null; then
    GIT_COMMIT_TRY="$(git rev-parse HEAD 2>/dev/null || true)"
    if [ -n "$GIT_COMMIT_TRY" ]; then
        COMMIT="$GIT_COMMIT_TRY"
        SHORT_COMMIT="$(printf '%s' "$COMMIT" | cut -c1-7)"
    fi
fi

mkdir -p "$(dirname "$OUT_FILE")"

cat > "$OUT_FILE" << EOF
{
  "version": "$VERSION",
  "commit": "$COMMIT",
  "shortCommit": "$SHORT_COMMIT",
  "branch": "$BRANCH",
  "buildTime": "$BUILD_TIME",
  "buildNumber": "$BUILD_NO",
  "builtBy": "$BUILT_BY"
}
EOF

echo "[gen-version] 已生成 $OUT_FILE"
cat "$OUT_FILE"
