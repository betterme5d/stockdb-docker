#!/usr/bin/env bash
# 增量同步：停服务 → 同步 → 拉起（LevelDB 独占数据目录，不停服同步会失败）
#
# 两种模式自动切换：
#   1) 有 docker compose / docker-compose → 走 compose（--profile sync）
#   2) 没有 compose 插件 → 走纯 docker CLI（命名卷，行为等价）
#
# 环境变量：
#   IMAGE / NAME / VOL_DATA / VOL_MYDB / HOST_PORT   见下方默认值
#   RUN_ON_WEEKEND=1   周六周日也同步（默认只在周一~周五跑）
#   LOCK_FILE          并发锁，防止上一次没跑完又起一次
#   LOG_FILE           同步日志
#
# 定时用法见 README「定时同步」。典型：交易日 18:30 主同步 + 次日 08:30 补同步。
set -euo pipefail

cd "$(dirname "$0")"

IMAGE="${IMAGE:-stockdb:0.3.5}"
NAME="${NAME:-stockdb}"
VOL_DATA="${VOL_DATA:-stockdb_data}"
VOL_MYDB="${VOL_MYDB:-stockdb_mydb}"
# ⚠️ 宿主机 7899 若已被 Windows 版 stockdb.exe 占用，需换端口
HOST_PORT="${HOST_PORT:-7899}"
RUN_ON_WEEKEND="${RUN_ON_WEEKEND:-0}"
LOCK_FILE="${LOCK_FILE:-/tmp/stockdb-sync.lock}"
LOG_FILE="${LOG_FILE:-$(pwd)/sync.log}"

log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"; }

# ---- 交易日判断（只排除周末；无法识别法定节假日，节假日同步是空操作）----
dow="$(date +%u)"   # 1=周一 ... 7=周日
if [ "$RUN_ON_WEEKEND" != "1" ] && [ "$dow" -ge 6 ]; then
    log "周末（dow=$dow），跳过。要强制跑请设 RUN_ON_WEEKEND=1"
    exit 0
fi

# ---- 并发锁：上一次没跑完就不要再起一次 ----
if ! mkdir "$LOCK_FILE" 2>/dev/null; then
    log "上一次同步尚未结束（锁 $LOCK_FILE 存在），本次跳过"
    exit 0
fi
trap 'rmdir "$LOCK_FILE" 2>/dev/null || true' EXIT

log "=== 开始同步 ==="

compose_bin=""
if docker compose version >/dev/null 2>&1; then
    compose_bin="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    compose_bin="docker-compose"
fi

if [ -n "$compose_bin" ]; then
    log "[模式] compose ($compose_bin)"
    log "[1/3] 停止 stockdb 服务..."
    $compose_bin stop stockdb
    log "[2/3] 增量同步数据..."
    $compose_bin --profile sync run --rm stockdb-sync 2>&1 | tee -a "$LOG_FILE"
    log "[3/3] 重新启动服务..."
    $compose_bin start stockdb
    log "=== 同步完成 ==="
    exit 0
fi

log "[模式] 纯 docker CLI（未检测到 compose 插件）"

log "[0/3] 确保卷存在..."
docker volume create "$VOL_DATA" >/dev/null
docker volume create "$VOL_MYDB" >/dev/null

log "[1/3] 停止 stockdb 服务..."
docker stop "$NAME" >/dev/null 2>&1 || log "  (服务未在运行，跳过)"

log "[2/3] 增量同步数据..."
# entrypoint 放行了 stockdb_updater 直通（且会补成绝对路径），
# 因此不会把镜像 CMD 里的配置文件路径追加进去
docker run --rm \
    -v "$VOL_DATA:/opt/stockdb/data" \
    -v "$VOL_MYDB:/opt/stockdb/mydb" \
    "$IMAGE" stockdb_updater 2>&1 | tee -a "$LOG_FILE"

log "[3/3] 重新启动服务..."
if docker ps -a --format '{{.Names}}' | grep -qx "$NAME"; then
    docker start "$NAME" >/dev/null
else
    docker run -d --name "$NAME" \
        -p "127.0.0.1:${HOST_PORT}:7899" \
        -v "$VOL_DATA:/opt/stockdb/data" \
        -v "$VOL_MYDB:/opt/stockdb/mydb" \
        "$IMAGE" >/dev/null
    log "  (宿主端口 ${HOST_PORT} → 容器 7899)"
fi

log "=== 同步完成：$(docker ps --filter name="^/${NAME}$" --format '{{.Names}} {{.Status}}') ==="
