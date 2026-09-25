#!/usr/bin/env bash
# devpi 的一行远程部署入口。devpi-ctl.sh 自己不够——它需要跟 Dockerfile/
# entrypoint.sh/docker-compose.yml 放在同一个目录里才能 docker compose 起来,
# 单独 curl 这一个文件 | bash 是不够的。这个脚本先把这几个文件拉齐,再跑
# devpi-ctl.sh,拼起来才是真正的"一行安装"。
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/wyunsi280-cell/infra-deploy/main/devpi/bootstrap.sh)"
#
# 注意是 `bash -c "$(curl ...)"`,不是 `curl ... | bash`——两者看着差不多,
# 交互体验完全不同:
#   - `curl url | bash`:bash 从 stdin 读脚本内容本身,stdin 被占用了,脚本
#     里 `read` 想要的键盘输入根本拿不到,只能读到 EOF(表现为一路默认值/
#     自动生成密码,不会真的停下来问你)。
#   - `bash -c "$(curl url)"`:脚本内容是当命令行参数传进去的,stdin 没被
#     占用,还是连着你的终端——脚本里的 `read` 能正常弹出来问你,是真正
#     的"一行搞定,过程中交互式填"。
#
# 装到别的目录(`bash -c "..." bash /custom/path`——第一个 "bash" 是占位的
# $0,真正的参数从第二个开始算 $1):
#   bash -c "$(curl -fsSL .../bootstrap.sh)" bash /custom/path
#
# 想完全不交互、自动化跑(CI 之类的场景),才用管道 + 环境变量这个组合:
#   export DEVPI_PASSWORD=your-password DEVPI_OUTSIDE_URL=https://devpi.example.com
#   curl -fsSL .../bootstrap.sh | bash

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
