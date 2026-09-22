# free-stockdb 官方发布包容器化
#
# 设计要点：
#   1. 自包含 —— 构建期从 GitHub Releases 下载官方发布包并校验 SHA256，
#      不再依赖手工解包，clone 下来直接 docker build 即可。
#   2. 单一 Dockerfile 支持两种架构（换 build-arg，不换文件）：
#        amd64: BASE_IMAGE=debian:bookworm-slim  ASSET_ARCH=manylinux-x64  (glibc)
#        arm64: BASE_IMAGE=alpine:3.20           ASSET_ARCH=alpine-arm64   (musl)
#   3. 发布版二进制没有 --host/--port 参数，监听地址只能靠改 stockdb.conf 的 server.ip。
#
# ⚠️ SHA256 取自 GitHub Releases API 的 asset digest（已与本地文件实测比对一致）。
#    换版本时必须同时改 RELEASE_TAG / ASSET_URL / ASSET_SHA256 三个变量。

ARG BASE_IMAGE=debian:bookworm-slim
FROM ${BASE_IMAGE}

# ---- 版本与发布包 ----
ARG STOCKDB_VERSION=0.3.5
ARG RELEASE_TAG=%E6%B5%8B%E8%AF%95%E7%89%88%E6%9C%AC0.3.5
ARG ASSET_ARCH=manylinux-x64
ARG ASSET_URL=https://github.com/hello245m/free-stockdb/releases/download/${RELEASE_TAG}/free-stockdb-${ASSET_ARCH}-v${STOCKDB_VERSION}-more-power.tar
ARG ASSET_SHA256=9ec47250f60cd35462446dfcf34db99ef33e6b73b3f02f0970ef329722c265cf
# 设为 1 可跳过校验（不推荐）
ARG SKIP_CHECKSUM=0

LABEL org.opencontainers.image.title="free-stockdb" \
      org.opencontainers.image.description="A股日K/分钟K 本地量化数据引擎（官方发布包容器化）" \
      org.opencontainers.image.version="${STOCKDB_VERSION}" \
      org.opencontainers.image.source="https://github.com/hello245m/free-stockdb" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.base.name="${BASE_IMAGE}"

ENV TZ=Asia/Shanghai \
    DEBIAN_FRONTEND=noninteractive \
    STOCKDB_HOME=/opt/stockdb

# ---- 运行时依赖 ----
# 服务端：libcurl（同步器）、OpenSSL（SHA256 校验）、libstdc++、zlib（LevelDB 压缩）
RUN set -eux; \
    if grep -qi alpine /etc/os-release; then \
        apk add --no-cache ca-certificates libcurl openssl libstdc++ zlib tzdata curl procps; \
    else \
        apt-get update; \
        apt-get install -y --no-install-recommends \
            ca-certificates libcurl4 libssl3 libstdc++6 zlib1g tzdata curl procps; \
        rm -rf /var/lib/apt/lists/*; \
    fi

WORKDIR /opt/stockdb

# ---- 下载并校验官方发布包 ----
# 校验写成「取值比对」而非 `sha256sum -c -`：后者在 busybox(alpine) 下行为不一致，
# 而 arm64 分支正是跑在 alpine 上。
RUN set -eux; \
    curl -fsSL -o /tmp/stockdb.tar "${ASSET_URL}"; \
    if [ "${SKIP_CHECKSUM}" != "1" ]; then \
        actual="$(sha256sum /tmp/stockdb.tar | awk '{print $1}')"; \
        if [ "$actual" != "${ASSET_SHA256}" ]; then \
            echo "SHA256 不匹配：期望 ${ASSET_SHA256}，实际 $actual" >&2; \
            exit 1; \
        fi; \
    fi; \
    tar -xf /tmp/stockdb.tar -C /opt/stockdb --strip-components=1; \
    rm -f /tmp/stockdb.tar

# ---- 整理：中文文件名 → ASCII，避免工具链/编码问题 ----
RUN set -eux; \
    cd /opt/stockdb; \
    [ -f "数据更新" ] && mv "数据更新" stockdb_updater || true; \
    [ -f "数据网页版.html" ] && mv "数据网页版.html" web.html || true; \
    rm -f "先看！这个！！使用说明.txt"; \
    chmod +x stockdb stockdb_updater; \
    mkdir -p data mydb

# ---- 关键改造：监听地址 127.0.0.1 → 0.0.0.0 ----
# 不改的话容器内只监听回环，端口映射形同虚设。
RUN set -eux; \
    sed -i \
        -e 's|127\.0\.0\.1|0.0.0.0|' \
        -e 's|pidfile = \./lgdb\.pid|pidfile = /tmp/lgdb.pid|' \
        -e 's|output: log\.txt|output: /dev/stdout|' \
        /opt/stockdb/stockdb.conf; \
    grep -E 'ip:|pidfile|output:' /opt/stockdb/stockdb.conf

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# 数据目录与私有库目录务必挂卷：镜像层写 23GB 数据既不现实也不可迁移
VOLUME ["/opt/stockdb/data", "/opt/stockdb/mydb"]

EXPOSE 7899

# 未识别的 cmd 也会返回 400 + JSON，拿到 200/400 都说明进程活着
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD code=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:7899/?cmd=len&t=%E6%97%A5k&key=000001"); \
        [ "$code" = "200" ] || [ "$code" = "400" ] || exit 1

ENTRYPOINT ["docker-entrypoint.sh"]
# 配置路径是必传位置参数；不加 -d 即前台进程，可直接作 PID 1
CMD ["/opt/stockdb/stockdb.conf"]
