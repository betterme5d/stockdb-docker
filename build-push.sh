#!/usr/bin/env bash
# 构建并推送 free-stockdb 镜像
#
# 用法：
#   ./build-push.sh                                  # 本地构建 linux/amd64
#   PLATFORM=linux/arm64 ./build-push.sh             # 构建 arm64（自动切 alpine 底 + alpine 发布包）
#   PUSH=1 REGISTRY=ghcr.io OWNER=yourname ./build-push.sh
#
# 注意：arm64 走 QEMU 模拟，只用来跑 apk/curl（发布包是官方预编译好的，不在容器里编译），
#      通常 1-2 分钟能完成。
set -euo pipefail

cd "$(dirname "$0")"

VERSION="${VERSION:-0.3.5}"
PLATFORM="${PLATFORM:-linux/amd64}"
REGISTRY="${REGISTRY:-ghcr.io}"
OWNER="${OWNER:-}"
IMAGE="${IMAGE:-}"
PUSH="${PUSH:-0}"

# 按目标架构选择「基础镜像 + 官方发布包 + 校验值」
# SHA256 来自 GitHub Releases API 的 asset digest（已与本地文件实测比对一致）
case "$PLATFORM" in
  *amd64*)
    BASE_IMAGE="debian:bookworm-slim"
    ASSET_ARCH="manylinux-x64"
    ASSET_SHA256="9ec47250f60cd35462446dfcf34db99ef33e6b73b3f02f0970ef329722c265cf"
    ;;
  *arm64*)
    BASE_IMAGE="alpine:3.20"
    ASSET_ARCH="alpine-arm64"
    ASSET_SHA256="40d98307e57d9153657352a1a4f89cda5d8c74615fc7f9a72d45a7dfe2132138"
    ;;
  *)
    echo "不支持的平台: $PLATFORM（仅 linux/amd64 与 linux/arm64）" >&2
    exit 1
    ;;
esac

if [ -z "$IMAGE" ]; then
  if [ -z "$OWNER" ]; then IMAGE="stockdb"; else IMAGE="${REGISTRY}/${OWNER}/stockdb"; fi
fi

TAGS=(-t "${IMAGE}:${VERSION}" -t "${IMAGE}:latest")

echo "==> 平台 ${PLATFORM} | 基础镜像 ${BASE_IMAGE} | 发布包 ${ASSET_ARCH}"
echo "==> 目标镜像 ${IMAGE}:${VERSION}"

BUILD_ARGS=(
  --platform "$PLATFORM"
  --build-arg "BASE_IMAGE=${BASE_IMAGE}"
  --build-arg "ASSET_ARCH=${ASSET_ARCH}"
  --build-arg "ASSET_SHA256=${ASSET_SHA256}"
  --build-arg "STOCKDB_VERSION=${VERSION}"
)

if docker buildx version >/dev/null 2>&1; then
  echo "==> 使用 buildx"
  if [ "$PUSH" = "1" ]; then
    docker buildx build "${BUILD_ARGS[@]}" "${TAGS[@]}" --push .
  else
    # buildx 默认不写入本地镜像列表，用 --load 才能 docker images 看到
    docker buildx build "${BUILD_ARGS[@]}" "${TAGS[@]}" --load .
  fi
else
  echo "==> buildx 不可用，退回 docker build（仅支持本机架构）"
  docker build \
    --build-arg "BASE_IMAGE=${BASE_IMAGE}" \
    --build-arg "ASSET_ARCH=${ASSET_ARCH}" \
    --build-arg "ASSET_SHA256=${ASSET_SHA256}" \
    --build-arg "STOCKDB_VERSION=${VERSION}" \
    "${TAGS[@]}" .
  if [ "$PUSH" = "1" ]; then
    docker push "${IMAGE}:${VERSION}"
    docker push "${IMAGE}:latest"
  fi
fi

echo "==> 完成: ${IMAGE}:${VERSION}"
