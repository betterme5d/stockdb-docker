#!/usr/bin/env bash
# 一键部署 / 幂等拉起：把「构建 → 建卷 → 自举数据 → 起服务 → 等健康 → 装定时任务」串成一条命令。
#
#   ./up.sh                  幂等拉起（数据已有时不会再下载）
#   ./up.sh --bootstrap      强制重跑首次全量自举（23GB，会二次确认）
#   ./up.sh --schedule       顺带安装定时任务
#   ./up.sh --status         只看状态，不做任何改动
#   ./up.sh --yes            跳过交互确认（配合 --bootstrap / --schedule 用于无人值守）
#
# ⚠️ 首次自举约 23GB，耗时几十分钟，建议在能长时间保持前台的终端里跑；
#    也可以用 nohup: nohup ./up.sh --yes > up.log 2>&1 &
set -euo pipefail

cd "$(dirname "$0")"

IMAGE="${IMAGE:-stockdb:0.3.5}"
NAME="${NAME:-stockdb}"
VOL_DATA="${VOL_DATA:-stockdb_data}"
VOL_MYDB="${VOL_MYDB:-stockdb_mydb}"
HOST_PORT="${HOST_PORT:-7899}"
BOOTSTRAP=0
SCHEDULE=0
STATUS_ONLY=0
ASSUME_YES=0

for a in "$@"; do
  case "$a" in
    --bootstrap) BOOTSTRAP=1 ;;
    --schedule)  SCHEDULE=1 ;;
    --status)    STATUS_ONLY=1 ;;
    -y|--yes)    ASSUME_YES=1 ;;
    -h|--help)   sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "未知参数: $a（-h 看用法）" >&2; exit 1 ;;
  esac
done

log()  { echo "[$(date '+%F %T')] $*"; }
die()  { echo "[$(date '+%F %T')][ERROR] $*" >&2; exit 1; }
ask()  { # $1=提示；返回 0=同意
  [ "$ASSUME_YES" = "1" ] && return 0
  printf '%s [y/N] ' "$1"; read -r r; case "$r" in y|Y|yes|YES) return 0;; *) return 1;; esac
}

command -v docker >/dev/null 2>&1 || die "找不到 docker"

# ---------- 状态 ----------
container_state() { docker ps -a --filter name="^/${NAME}$" --format '{{.Status}}' 2>/dev/null | head -1; }
health_state()    {
  h="$(docker inspect --format '{{.State.Health.Status}}' "$NAME" 2>/dev/null | head -1)"
  echo "${h:-none}"
}
# 端口探测：返回 HTTP 状态码；空串表示没有服务在听。
# 注意 stockdb 对非法请求也返回 400，所以不能只看 curl 的退出码。
port_code() { curl -s -o /dev/null -m 3 -w '%{http_code}' "http://127.0.0.1:${HOST_PORT}/" 2>/dev/null || true; }
data_ready() {
  docker run --rm -v "$VOL_DATA:/opt/stockdb/data" "$IMAGE" \
      sh -c '[ -f /opt/stockdb/data/CURRENT ] && echo ready || echo empty' 2>/dev/null || echo "unknown"
}

if [ "$STATUS_ONLY" = "1" ]; then
  echo "镜像:   $(docker image inspect "$IMAGE" --format '{{.Id}} {{.Size}}' 2>/dev/null || echo '不存在')"
  echo "容器:   ${NAME} -> $(container_state || echo '不存在')"
  echo "健康:   $(health_state)"
  echo "数据卷: ${VOL_DATA} -> $(data_ready)"
  code="$(port_code)"
  echo "端口:   127.0.0.1:${HOST_PORT} -> ${code:-无响应}"
  exit 0
fi

log "=== free-stockdb 一键部署 ==="

# ---------- 1. 镜像 ----------
if docker image inspect "$IMAGE" >/dev/null 2>&1; then
  log "[1/6] 镜像已存在: $IMAGE"
else
  log "[1/6] 镜像不存在，开始构建..."
  ./build-push.sh
fi

# ---------- 2. 卷 ----------
log "[2/6] 确保数据卷存在..."
docker volume create "$VOL_DATA" >/dev/null
docker volume create "$VOL_MYDB" >/dev/null

# ---------- 3. 数据自举 ----------
state="$(data_ready)"
if [ "$state" = "empty" ] || [ "$BOOTSTRAP" = "1" ]; then
  if [ "$BOOTSTRAP" = "1" ] && [ "$state" = "ready" ]; then
    log "[3/6] 数据已存在，但指定了 --bootstrap，将重跑全量自举"
    ask "这会重新校验/拉取约 23GB 数据，确认继续？" || { log "已取消"; exit 0; }
  else
    log "[3/6] 数据卷为空，需要首次自举（约 23GB，几十分钟）"
    ask "确认开始下载全量数据？" || { log "已取消。可稍后手动跑: ./up.sh --bootstrap"; exit 0; }
  fi
  log "    开始自举，日志会实时打印（Ctrl+C 可中断，已下载部分支持断点续传）..."
  docker run --rm \
      -v "$VOL_DATA:/opt/stockdb/data" \
      -v "$VOL_MYDB:/opt/stockdb/mydb" \
      "$IMAGE" stockdb_updater
  state="$(data_ready)"
  [ "$state" = "ready" ] || die "自举后仍未检测到 CURRENT，数据可能不完整"
else
  log "[3/6] 数据已就绪，跳过自举"
fi

# ---------- 4. 端口冲突检查 ----------
code="$(port_code)"
if [ -n "$code" ]; then
  if ! docker ps --filter name="^/${NAME}$" --format '{{.Names}}' | grep -qx "$NAME"; then
    die "宿主端口 ${HOST_PORT} 已被其他进程占用（HTTP $code，很可能是 Windows 版 stockdb.exe）。
     请先停掉它，或换端口： HOST_PORT=7890 ./up.sh"
  fi
  log "    端口 ${HOST_PORT} 已被本容器占用，跳过冲突检查"
else
  log "[4/6] 端口 ${HOST_PORT} 空闲"
fi

# ---------- 5. 起服务 ----------
log "[5/6] 启动服务..."
if docker ps -a --format '{{.Names}}' | grep -qx "$NAME"; then
  if docker ps --format '{{.Names}}' | grep -qx "$NAME"; then
    log "    容器已在运行"
  else
    docker start "$NAME" >/dev/null && log "    已启动已有容器"
  fi
else
  docker run -d --name "$NAME" \
      --restart unless-stopped \
      -p "127.0.0.1:${HOST_PORT}:7899" \
      -v "$VOL_DATA:/opt/stockdb/data" \
      -v "$VOL_MYDB:/opt/stockdb/mydb" \
      "$IMAGE" >/dev/null
  log "    已创建并启动（宿主端口 ${HOST_PORT} → 容器 7899，restart=unless-stopped）"
fi

# ---------- 6. 等健康 ----------
log "[6/6] 等待健康检查..."
for i in $(seq 1 30); do
  h="$(health_state)"
  [ "$h" = "healthy" ] && { log "    健康: healthy（耗时 ~$((i*2))s）"; break; }
  [ "$h" = "unhealthy" ] && { docker logs --tail 20 "$NAME"; die "健康检查失败，见上方日志"; }
  sleep 2
done
[ "$(health_state)" = "healthy" ] || die "等待健康检查超时（60s）"

# ---------- 可选：装定时任务 ----------
if [ "$SCHEDULE" = "1" ]; then
  log "==> 安装定时任务（交易日 18:30 主同步 + 次日 08:30 补同步）..."
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
      # Windows：交给任务计划程序（Git Bash 里没有 cron）
      WIN_DIR="$(pwd -W 2>/dev/null || pwd)"
      WIN_DIR="${WIN_DIR//\//\\}"   # PowerShell 更吃反斜杠
      if command -v powershell.exe >/dev/null 2>&1; then
        powershell.exe -ExecutionPolicy Bypass -File "$WIN_DIR\\schedule\\install-task.ps1"
      else
        log "    未找到 powershell.exe，请手动执行："
        log "    powershell -ExecutionPolicy Bypass -File .\\schedule\\install-task.ps1"
      fi
      ;;
    *)
      if command -v crontab >/dev/null 2>&1 && [ -f schedule/install-cron.sh ]; then
        ./schedule/install-cron.sh
      else
        log "    未检测到 crontab，跳过（可手动把下面两行加进 crontab）："
        log "    30 18 * * 1-5 cd $(pwd) && ./sync.sh >> $(pwd)/sync.log 2>&1"
        log "    30 8  * * 1-5 cd $(pwd) && ./sync.sh >> $(pwd)/sync.log 2>&1"
      fi
      ;;
  esac
fi

echo
log "=== 部署完成 ==="
echo "  服务:   http://127.0.0.1:${HOST_PORT}/  (容器 ${NAME}, $(container_state))"
echo "  数据:   卷 ${VOL_DATA}"
echo "  手动同步:   ./sync.sh"
echo "  查看状态:   ./up.sh --status"
echo "  实时日志:   docker logs -f ${NAME}"
if [ "$SCHEDULE" != "1" ]; then
  echo "  装定时任务: ./up.sh --schedule"
fi
