#!/usr/bin/env bash
# Linux / WSL：把 sync.sh 装进 crontab（每个交易日跑两次）
#
#   ./schedule/install-cron.sh          安装
#   ./schedule/install-cron.sh --remove 移除
#
# 为什么跑两次：
#   18:30 —— 收盘后主同步（镜像一般在收盘后到夜间发布）
#   08:30 —— 次日补一次，兜住前一晚发布延迟的情况
#   首次是全量 23GB，之后都是增量，重复跑很便宜。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/sync.sh"
LOG="$ROOT/sync.log"

# 周一~周五 18:30 与 08:30
ENTRIES=(
    "30 18 * * 1-5 cd $ROOT && ./sync.sh >> $LOG 2>&1"
    "30 8  * * 1-5 cd $ROOT && ./sync.sh >> $LOG 2>&1"
)

if [ "${1:-}" = "--remove" ]; then
    echo "==> 移除已有条目"
    crontab -l 2>/dev/null | grep -v "stockdb-docker/sync.sh\|cd $ROOT && ./sync.sh" | crontab - || true
    echo "完成"
    exit 0
fi

command -v crontab >/dev/null 2>&1 || { echo "找不到 crontab" >&2; exit 1; }

existing="$(crontab -l 2>/dev/null || true)"
new="$existing"
for e in "${ENTRIES[@]}"; do
    if printf '%s\n' "$existing" | grep -Fqx "$e"; then
        echo "==> 已存在，跳过：$e"
    else
        echo "==> 新增：$e"
        new="$new
$e"
    fi
done

printf '%s\n' "$new" | grep -v '^$' | crontab -
echo "==> 当前 crontab："
crontab -l | grep -E "sync.sh" || true
