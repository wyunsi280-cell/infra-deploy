#!/usr/bin/env bash
# 脚手架一个新的内部共享库仓库——照着 fastapi-admin-core 那一套模板
# (uv + hatchling + 可选 Cython 编译保护 + GitHub Actions 测试/发布到 devpi)。
# 跑起来问几个问题就行,不用手动一步步抄文件。
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/wyunsi280-cell/infra-deploy/main/scaffold-lib.sh)"
#
# 需要:gh(GitHub CLI,已登录)、uv、git。
#
# docker 不是必须的——只是"如果这台机器刚好能连到装 devpi 的那个容器"时,
# 用来自动查 vendor 密码的一个小便利(devpi 跟这台机器不在一起,或者压根没装
# docker,都无所谓,查不到就会问你手动输入,不会卡住)。devpi 迁到独立服务器
# 长期运行之后,这个自动查询大概率会失效,到时候手动输入密码就行,是同一套
# 已经测过的交互流程。

set -euo pipefail

echo "==================================================="
echo " 新建内部共享库(仿 fastapi-admin-core 模板)"
echo "==================================================="

read -r -p "库名(小写字母+连字符,比如 my-new-lib): " LIB_NAME
if [ -z "${LIB_NAME}" ]; then
  echo "取消。" >&2
  exit 1
fi
PKG_NAME="$(echo "${LIB_NAME}" | tr '-' '_')"

read -r -p "一句话描述: " LIB_DESC

read -r -p "GitHub 组织/用户名(直接回车用 wyunsi280-cell): " GH_OWNER
GH_OWNER="${GH_OWNER:-wyunsi280-cell}"

read -r -p "要不要跟 fastapi-admin-core 一样编译成 .so 隐藏源码?(Y/n,直接回车=要): " COMPILE_ANSWER
COMPILE_ANSWER="${COMPILE_ANSWER:-y}"
COMPILE_PROTECT=1
case "${COMPILE_ANSWER}" in
  [nN]*) COMPILE_PROTECT=0 ;;
esac

read -r -p "发布到哪个 devpi 索引?(直接回车用 vendor/prod): " DEVPI_INDEX
DEVPI_INDEX="${DEVPI_INDEX:-vendor/prod}"

read -r -p "devpi 公网地址(直接回车用 https://devpi.touks.eu.org): " DEVPI_URL_INPUT
DEVPI_URL_INPUT="${DEVPI_URL_INPUT:-https://devpi.touks.eu.org}"

DEVPI_PASSWORD="${DEVPI_PASSWORD:-}"
if [ -z "${DEVPI_PASSWORD}" ]; then
  DEVPI_PASSWORD="$(docker inspect devpi-devpi-1 --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
    | grep '^DEVPI_PASSWORD=' | head -1 | cut -d= -f2- || true)"
fi
if [ -z "${DEVPI_PASSWORD}" ]; then
  read -r -s -p "查不到 devpi 密码(devpi 容器没在跑?),手动输入 vendor 密码: " DEVPI_PASSWORD
  echo
fi
if [ -z "${DEVPI_PASSWORD}" ]; then
  echo "错误: 没有 devpi 密码没法配 GitHub secret。" >&2
  exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "错误: 没找到 gh(GitHub CLI),先装好并 gh auth login。" >&2
  exit 1
fi
if ! command -v uv >/dev/null 2>&1; then
  echo "错误: 没找到 uv。" >&2
  exit 1
fi

read -r -p "建在哪个目录下面(项目文件夹会建在这个目录里面,目录不存在会自动建;直接回车用当前目录): " BASE_DIR
BASE_DIR="${BASE_DIR:-.}"
mkdir -p "${BASE_DIR}"
cd "${BASE_DIR}"

TARGET_DIR="${LIB_NAME}"
if [ -e "${TARGET_DIR}" ]; then
  echo "错误: $(pwd)/${TARGET_DIR} 已经存在了,换个名字或者先处理掉。" >&2
  exit 1
fi

echo ""
echo "==> 建 GitHub 仓库 ${GH_OWNER}/${LIB_NAME}(private)"
gh repo create "${GH_OWNER}/${LIB_NAME}" --private --description "${LIB_DESC}"

echo "==> 脚手架本地项目"
uv init --name "${LIB_NAME}" --lib "${TARGET_DIR}"
cd "${TARGET_DIR}"

if [ "${COMPILE_PROTECT}" = "1" ]; then
  mkdir -p hatch_build_hooks
  cat > hatch_build_hooks/tag_native.py << 'EOF'
from hatchling.builders.hooks.plugin.interface import BuildHookInterface


class NativeTagHook(BuildHookInterface):
    def initialize(self, version, build_data):
        build_data["pure_python"] = False
        build_data["infer_tag"] = True
EOF
fi

cat > pyproject.toml << EOF
[project]
name = "${LIB_NAME}"
version = "0.1.0"
description = "${LIB_DESC}"
readme = "README.md"
requires-python = ">=3.13"
dependencies = [
]

[dependency-groups]
dev = [
    "pytest>=8.0.0",
    "pytest-asyncio>=0.24.0",
    "bandit>=1.7.0",
    "pip-audit>=2.7.0",
]

[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"

[tool.hatch.build.targets.wheel]
packages = ["src/${PKG_NAME}"]
EOF

if [ "${COMPILE_PROTECT}" = "1" ]; then
  cat >> pyproject.toml << 'EOF'

[tool.hatch.build.hooks.custom]
path = "hatch_build_hooks/tag_native.py"
EOF
fi

cat >> pyproject.toml << 'EOF'

[tool.pytest.ini_options]
asyncio_mode = "auto"
EOF

echo "==> 写 publish.sh"
if [ "${COMPILE_PROTECT}" = "1" ]; then
  curl -fsSL "https://raw.githubusercontent.com/wyunsi280-cell/infra-deploy/main/publish-compiled-template.sh" -o publish.sh
  # 模板里下划线形式(包名/PKG_ROOT/wheel文件名)和连字符形式(docker镜像tag/
  # 提示信息里的库名)都要换,两种形式分开替换。
  sed -i "s/fastapi_admin_core/${PKG_NAME}/g" publish.sh
  sed -i "s/fastapi-admin-core/${LIB_NAME}/g" publish.sh
  sed -i "s#DEVPI_INDEX:-vendor/prod#DEVPI_INDEX:-${DEVPI_INDEX}#" publish.sh
  sed -i "s#DEVPI_URL:-https://devpi.touks.eu.org#DEVPI_URL:-${DEVPI_URL_INPUT}#" publish.sh
else
  cat > publish.sh << EOF
#!/usr/bin/env bash
# 打包 ${LIB_NAME} 成 wheel(纯 Python,不编译),上传到私有 devpi 索引。
#
# 用法: ./publish.sh [版本号]  # 不传就自己从 pyproject.toml 读

set -euo pipefail
SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"

DEVPI_URL="\${DEVPI_URL:-${DEVPI_URL_INPUT}}"
DEVPI_INDEX="\${DEVPI_INDEX:-${DEVPI_INDEX}}"
DEVPI_USER="\${DEVPI_USER:-vendor}"

VERSION="\${1:-}"
if [ -z "\${VERSION}" ]; then
  VERSION="\$(grep -m1 '^version = ' "\${SCRIPT_DIR}/pyproject.toml" | sed -E 's/version = "(.*)"/\\1/')"
  echo "==> 没传版本号,从 pyproject.toml 读到: \${VERSION}"
fi

if [ -z "\${DEVPI_PASSWORD:-}" ]; then
  DEVPI_PASSWORD="\$(docker inspect devpi-devpi-1 --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \\
    | grep '^DEVPI_PASSWORD=' | head -1 | cut -d= -f2-)"
fi
if [ -z "\${DEVPI_PASSWORD:-}" ]; then
  echo "错误: 没有设置 DEVPI_PASSWORD,也从 devpi-devpi-1 容器里查不到。" >&2
  exit 1
fi
if ! command -v devpi >/dev/null 2>&1; then
  echo "错误: 没找到 devpi 命令,先装一下: pip install devpi-client" >&2
  exit 1
fi

cd "\${SCRIPT_DIR}"
rm -rf dist
uv build --wheel

WHEEL="\$(ls dist/*.whl | sort -V | tail -1)"
if [[ "\$(basename "\${WHEEL}")" != ${PKG_NAME}-\${VERSION}-* ]]; then
  echo "错误: 传入的版本号 \${VERSION} 跟 pyproject.toml 里实际的版本对不上(wheel: \$(basename "\${WHEEL}"))" >&2
  exit 1
fi

DEVPI_SCHEME="\${DEVPI_URL%%://*}"
DEVPI_HOST="\${DEVPI_URL#*://}"
devpi use "\${DEVPI_SCHEME}://\${DEVPI_USER}:\${DEVPI_PASSWORD}@\${DEVPI_HOST}/\${DEVPI_INDEX}"
devpi login "\${DEVPI_USER}" --password "\${DEVPI_PASSWORD}"
devpi upload "\${WHEEL}"

echo ""
echo "发布完成: ${LIB_NAME} \${VERSION} -> \${DEVPI_URL}/\${DEVPI_INDEX}"
EOF
fi
chmod +x publish.sh

echo "==> 写一个占位测试(没有它的话,第一次 CI 跑 pytest 会因为\"0 个测试\"报错退出,
误导人以为哪里坏了——等你写了真测试,把这个占位的删掉就行)"
mkdir -p tests
cat > tests/test_placeholder.py << 'EOF'
def test_placeholder():
    """占位测试,写了真测试之后删掉这个文件。"""
    assert True
EOF

echo "==> 写 CI 配置"
mkdir -p .github/workflows
cat > .github/workflows/test.yml << 'EOF'
name: Test

on:
  push:
  pull_request:

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install uv
        uses: astral-sh/setup-uv@v3

      - name: Install dependencies
        run: uv sync

      - name: Security lint (bandit)
        run: uv run bandit -r src -q

      - name: Dependency vulnerability scan (pip-audit)
        run: uv run pip-audit

      - name: Run tests
        run: uv run pytest -v
EOF

cat > .github/workflows/release.yml << 'EOF'
name: Release to devpi

on:
  push:
    tags:
      - "v*"

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install uv
        uses: astral-sh/setup-uv@v3
      - name: Install dependencies
        run: uv sync
      - name: Security lint (bandit)
        run: uv run bandit -r src -q
      - name: Dependency vulnerability scan (pip-audit)
        run: uv run pip-audit
      - name: Run tests
        run: uv run pytest -v

  publish:
    needs: test
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install devpi-client
        run: pip install --quiet devpi-client
      - name: Build and publish to devpi
        env:
          DEVPI_URL: ${{ secrets.DEVPI_URL }}
          DEVPI_PASSWORD: ${{ secrets.DEVPI_PASSWORD }}
        run: |
          VERSION="${GITHUB_REF_NAME#v}"
          bash publish.sh "${VERSION}"
EOF

echo "==> 配 GitHub secrets"
gh secret set DEVPI_URL --repo "${GH_OWNER}/${LIB_NAME}" --body "${DEVPI_URL_INPUT}"
gh secret set DEVPI_PASSWORD --repo "${GH_OWNER}/${LIB_NAME}" --body "${DEVPI_PASSWORD}"

echo "==> 首次提交 + 推送"
git add -A
git commit -m "Initial scaffold" >/dev/null
git branch -M main
git remote add origin "https://github.com/${GH_OWNER}/${LIB_NAME}.git"
git push -u origin main

FULL_PATH="$(pwd)"
echo ""
echo "==================================================="
echo "脚手架完成: ${FULL_PATH}"
echo "仓库: https://github.com/${GH_OWNER}/${LIB_NAME}"
echo ""
echo "写完代码之后发第一个版本:"
echo "  cd \"${FULL_PATH}\""
echo "  git add -A && git commit -m \"...\""
echo "  git tag v0.1.0 && git push origin main && git push origin v0.1.0"
echo "==================================================="
