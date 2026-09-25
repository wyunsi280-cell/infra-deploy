#!/usr/bin/env bash
# devpi 的一行远程部署入口。devpi-ctl.sh 自己不够——它需要跟 Dockerfile/
# entrypoint.sh/docker-compose.yml 放在同一个目录里才能 docker compose 起来,
# 单独 curl 这一个文件 | bash 是不够的。这个脚本先把这几个文件拉齐,再跑
# devpi-ctl.sh,拼起来才是真正的"一行安装"。
#
#   curl -fsSL https://raw.githubusercontent.com/wyunsi280-cell/infra-deploy/main/devpi/bootstrap.sh | bash
#
# 装到别的目录:
#   curl -fsSL .../bootstrap.sh | bash -s -- /custom/path
#
# 管道运行时 stdin 不是终端,devpi-ctl.sh 不会弹交互提示,会自动生成密码、
# 不配外部域名。想指定自己的密码/域名,用环境变量传(exec 会带过去):
#   export DEVPI_PASSWORD=your-password DEVPI_OUTSIDE_URL=https://devpi.example.com
#   curl -fsSL .../bootstrap.sh | bash
# 或者干脆下载下来直接跑(stdin 是真终端,会正常弹交互提示):
#   curl -fsSL .../bootstrap.sh -o bootstrap.sh && bash bootstrap.sh

set -euo pipefail

RAW_BASE="https://raw.githubusercontent.com/wyunsi280-cell/infra-deploy/main/devpi"
TARGET_DIR="${1:-${HOME}/infra/devpi}"

mkdir -p "${TARGET_DIR}"
cd "${TARGET_DIR}"

for f in Dockerfile entrypoint.sh docker-compose.yml devpi-ctl.sh; do
  curl -fsSL "${RAW_BASE}/${f}" -o "${f}"
done
chmod +x devpi-ctl.sh entrypoint.sh

echo "已下载到 ${TARGET_DIR},开始安装..."
exec bash devpi-ctl.sh install
