#!/bin/sh
# free-stockdb 容器入口
#
# 发布版二进制没有 --host/--port，只能传配置文件路径：
#   stockdb [-d] /path/to/stockdb.conf [-s start|stop|restart]
# 这里保持前台运行（不加 -d），使其能作为容器 PID 1。
#
# 环境变量（可选）：
#   STOCKDB_PORT  覆盖 server.port（默认 7899）
#   STOCKDB_BIND  覆盖 server.ip（默认 0.0.0.0）
set -eu

# 允许 docker run <img> sh / bash / stockdb_updater ... 这类调试与旁路用法，
# 否则第一个参数会被当成配置文件路径。
# ⚠️ stockdb / stockdb_updater 不在 PATH 里，必须补成绝对路径，否则 exec 报 not found。
case "${1:-}" in
  sh|bash) exec "$@" ;;
  stockdb|stockdb_updater) bin="/opt/stockdb/$1"; shift; exec "$bin" "$@" ;;
esac

CONF="${1:-/opt/stockdb/stockdb.conf}"
shift 2>/dev/null || true

if [ ! -f "$CONF" ]; then
    echo "[entrypoint] 找不到配置文件: $CONF" >&2
    exit 1
fi

# 需要覆盖端口/监听地址时，复制一份配置到 /tmp 再改写，不动镜像内的原文件。
# 用「字面量替换」而不是带捕获组的正则：镜像内 conf 的基准值固定为 port: 7899 /
# ip: 0.0.0.0，字面替换在 GNU sed 与 busybox sed 上行为一致，且不碰缩进。
if [ -n "${STOCKDB_PORT:-}" ] || [ -n "${STOCKDB_BIND:-}" ]; then
    RT=/tmp/stockdb.runtime.conf
    cp "$CONF" "$RT"
    if [ -n "${STOCKDB_BIND:-}" ]; then
        sed -i "s|ip: 0.0.0.0|ip: ${STOCKDB_BIND}|" "$RT"
    fi
    if [ -n "${STOCKDB_PORT:-}" ]; then
        sed -i "s|port: 7899|port: ${STOCKDB_PORT}|" "$RT"
    fi
    CONF="$RT"
fi

# stockdb 以 create_if_missing=false 打开 LevelDB，空目录会直接失败。
# 这里提前给出可操作的提示，避免只看到一行晦涩的 "open leveldb failed"。
if [ -z "$(ls -A /opt/stockdb/data 2>/dev/null)" ]; then
    echo "[entrypoint][warn] /opt/stockdb/data 是空的。" >&2
    echo "[entrypoint][warn] stockdb 不会自建数据库，服务会报 open leveldb failed。" >&2
    echo "[entrypoint][warn] 请先自举数据：docker compose --profile sync run --rm stockdb-sync" >&2
fi

exec /opt/stockdb/stockdb "$CONF" "$@"
