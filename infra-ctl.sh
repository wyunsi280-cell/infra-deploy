#!/usr/bin/env bash
# 基础设施管理统一入口——Harbor、devpi 都在这一个脚本里选,不用分别记两个
# curl 地址。选了之后委托给各自现有、已经单独测过的 harbor-ctl.sh/
# devpi-ctl.sh,这两个脚本本身没有任何改动,直接一行远程也照样能单独用。
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/wyunsi280-cell/infra-deploy/main/infra-ctl.sh)"

set -euo pipefail

RAW_BASE="https://raw.githubusercontent.com/wyunsi280-cell/infra-deploy/main"

show_menu() {
  while true; do
    echo ""
    echo "================ 基础设施管理 ================"
    echo "1) Harbor(Docker 镜像仓库)"
    echo "2) devpi(私有 Python 包索引)"
    echo "0) 退出"
    echo "==============================================="
    read -r -p "请输入序号: " choice
    case "${choice}" in
      1) bash -c "$(curl -fsSL "${RAW_BASE}/harbor/harbor-ctl.sh")" ;;
      2) bash -c "$(curl -fsSL "${RAW_BASE}/devpi/devpi-ctl.sh")" ;;
      0) echo "退出。"; exit 0 ;;
      *) echo "无效选项,请重新输入。" ;;
    esac
  done
}

show_menu
