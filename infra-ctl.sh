#!/usr/bin/env bash
# 基础设施管理统一入口——Harbor、devpi、license-system 的 key 管理都在这
# 一个脚本里选,不用分别记好几个 curl 地址。选了之后委托给各自现有、已经
# 单独测过的 harbor-ctl.sh/devpi-ctl.sh/license-ctl.sh,这几个脚本本身没有
# 任何改动,直接一行远程也照样能单独用。
#
# license 那一项管的是"给已部署好的 license-system 签发/查询/吊销/恢复
# key"——不是部署 license-system 本身。license-system 的镜像是从私有仓库
# 现场编译的,不是像 Harbor/devpi 那样拉官方现成镜像,装/重装服务本身做不到
# 公开一行部署,得去 license-system 私有仓库里手动 `docker compose up -d
# --build`。
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
    echo "3) license(签发/查询/吊销/恢复 key,不含部署)"
    echo "0) 退出"
    echo "==============================================="
    read -r -p "请输入序号: " choice
    case "${choice}" in
      1) bash -c "$(curl -fsSL "${RAW_BASE}/harbor/harbor-ctl.sh")" ;;
      2) bash -c "$(curl -fsSL "${RAW_BASE}/devpi/devpi-ctl.sh")" ;;
      3) bash -c "$(curl -fsSL "${RAW_BASE}/license/license-ctl.sh")" ;;
      0) echo "退出。"; exit 0 ;;
      *) echo "无效选项,请重新输入。" ;;
    esac
  done
}

show_menu
