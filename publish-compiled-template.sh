#!/usr/bin/env bash
# 编译 fastapi_admin_core 自己(.py -> .so),用 uv build 打成 wheel,
# 上传到私有 devpi 索引。
#
# 用法: ./publish.sh [版本号]  # 不传就自己从 pyproject.toml 读
# 需要 host 上有 docker(编译 .so 这一步是硬需求,跑在哪台机器都要有)和
# devpi-client(`uv tool install devpi-client` 或 `pip install devpi-client`)。
#
# 密码优先从本机的 devpi 容器(devpi-devpi-1)自动查,跟 devpi-ctl.sh 的
# credentials 命令同一个道理——但这只在"编译发布的机器"跟"devpi 本身"是
# 同一台时才查得到。devpi 迁到独立服务器长期跑之后,这个自动查询会查不到,
# 到时候手动传 DEVPI_PASSWORD 环境变量就行(报错信息里也会提醒)。
# 要覆盖默认值就设 DEVPI_URL/DEVPI_INDEX/DEVPI_USER/DEVPI_PASSWORD 环境变量。

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ============ 配置(要改就改这几行,环境变量传入的话这里的默认值不生效) ============
DEVPI_URL="${DEVPI_URL:-https://devpi.touks.eu.org}"
DEVPI_INDEX="${DEVPI_INDEX:-vendor/prod}"
DEVPI_USER="${DEVPI_USER:-vendor}"
# DEVPI_PASSWORD 不在这里写死默认值——见下面的自动获取逻辑
# ================================================================================

if ! command -v docker >/dev/null 2>&1; then
  echo "错误: 没有检测到 docker 命令。这台机器(或这个终端)连不到 docker,去能连到 docker 的地方跑本脚本。" >&2
  exit 1
fi

VERSION="${1:-}"
if [ -z "${VERSION}" ]; then
  VERSION="$(grep -m1 '^version = ' "${SCRIPT_DIR}/pyproject.toml" | sed -E 's/version = "(.*)"/\1/')"
  echo "==> 没传版本号,从 pyproject.toml 读到: ${VERSION}"
fi

if [ -z "${DEVPI_PASSWORD:-}" ]; then
  DEVPI_PASSWORD="$(docker inspect devpi-devpi-1 --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
    | grep '^DEVPI_PASSWORD=' | head -1 | cut -d= -f2-)"
fi
if [ -z "${DEVPI_PASSWORD:-}" ]; then
  echo "错误: 没有设置 DEVPI_PASSWORD,也从 devpi-devpi-1 容器里查不到(容器没在跑?),没法自动获取密码。" >&2
  echo "手动设一下: DEVPI_PASSWORD=xxx $0 ${VERSION}" >&2
  exit 1
fi
if ! command -v devpi >/dev/null 2>&1; then
  echo "错误: 没找到 devpi 命令,先装一下: pip install devpi-client (或 uv tool install devpi-client)" >&2
  exit 1
fi

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "${BUILD_DIR}"' EXIT

echo "==> 复制源码到临时目录"
cp -r "${SCRIPT_DIR}/." "${BUILD_DIR}/"
rm -rf "${BUILD_DIR}/.git" "${BUILD_DIR}/.github" "${BUILD_DIR}/.pytest_cache" \
       "${BUILD_DIR}/.ruff_cache" "${BUILD_DIR}/.vscode" "${BUILD_DIR}/.venv" \
       "${BUILD_DIR}/dist" "${BUILD_DIR}/build"
find "${BUILD_DIR}" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true

cat > "${BUILD_DIR}/_compile.py" << 'EOF'
"""编译 src/fastapi_admin_core 下所有 .py(除 __init__.py)为 .so,
删除源码和编译中间产物,不留明文。"""
import glob
import os
import subprocess
import sys

PKG_ROOT = "src/fastapi_admin_core"
py_files = [
    f for f in glob.glob(f"{PKG_ROOT}/**/*.py", recursive=True)
    if os.path.basename(f) != "__init__.py"
]

script = """
import os
from Cython.Build import cythonize
from setuptools import Extension, setup
files = %r
# 模块名相对 src/ 算(不带 "src." 前缀),配合 package_dir={"":"src"} 显式声明——
# 踩过坑: cwd 里同时有 pyproject.toml(声明了 [project])和顶层 src/ 目录时,
# setuptools 会自动套用 src-layout 探测(package_dir={"":"src"}),如果这里的
# Extension 名还带着 "src." 前缀,两边的 "src" 会叠加,产物被复制到
# src/src/... 这种不存在的路径,直接报错退出。
exts = [
    Extension(os.path.relpath(f, "src")[:-3].replace(os.sep, "."), [f])
    for f in files
]
setup(
    package_dir={"": "src"},
    ext_modules=cythonize(exts, compiler_directives={"language_level": "3"}, quiet=True),
    script_args=["build_ext", "--inplace"],
)
""" % (py_files,)
subprocess.run([sys.executable, "-c", script], check=True)

for f in py_files:
    os.remove(f)
    c_file = f[:-3] + ".c"
    if os.path.exists(c_file):
        os.remove(c_file)
EOF

cat > "${BUILD_DIR}/Dockerfile" << 'DOCKEREOF'
FROM python:3.13-slim
RUN apt-get update && apt-get install -y --no-install-recommends gcc g++ python3-dev \
    && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir cython setuptools uv
WORKDIR /build
COPY . .
RUN python _compile.py
RUN uv build --wheel
DOCKEREOF

echo "==> Docker 构建(编译 .so + 打 wheel,跟消费方用同一个 python:3.13-slim 基础环境,保证 ABI 一致)"
DOCKER_BUILDKIT=1 docker build -t fastapi-admin-core-builder:latest "${BUILD_DIR}"

echo "==> 取出 wheel"
CID="$(docker create fastapi-admin-core-builder:latest true)"
mkdir -p "${SCRIPT_DIR}/dist"
rm -f "${SCRIPT_DIR}"/dist/*.whl
docker cp "${CID}:/build/dist/." "${SCRIPT_DIR}/dist/"
docker rm -f "${CID}" >/dev/null

WHEEL="$(ls "${SCRIPT_DIR}"/dist/*.whl | sort -V | tail -1)"
if [[ "$(basename "${WHEEL}")" != fastapi_admin_core-${VERSION}-* ]]; then
  echo "错误: 传入的版本号 ${VERSION} 跟 pyproject.toml 里实际的版本对不上(wheel: $(basename "${WHEEL}"))" >&2
  echo "先改 pyproject.toml 里的 version 字段,再传一致的版本号" >&2
  exit 1
fi

echo "==> 上传到 devpi: ${WHEEL}"
# devpi use 也要走 Caddy 那层 Basic Auth(它先探测一次 +api 端点),账号密码
# 直接嵌进 URL 里传,不能等后面 devpi login 才带凭证——探测那一步没凭证会被
# Caddy 拦成 401,devpi 客户端遇到这个探测失败就不会正确记住"当前指向哪个
# index",后面的 login/upload 会用到过期缓存的旧地址,一样失败。
DEVPI_SCHEME="${DEVPI_URL%%://*}"
DEVPI_HOST="${DEVPI_URL#*://}"
devpi use "${DEVPI_SCHEME}://${DEVPI_USER}:${DEVPI_PASSWORD}@${DEVPI_HOST}/${DEVPI_INDEX}"
devpi login "${DEVPI_USER}" --password "${DEVPI_PASSWORD}"
devpi upload "${WHEEL}"

echo ""
echo "发布完成: fastapi_admin_core ${VERSION} -> ${DEVPI_URL}/${DEVPI_INDEX}"
