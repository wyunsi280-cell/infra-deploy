#!/usr/bin/env bash
# 基础设施管理统一入口——Harbor、devpi、license-system(key管理+部署)都在
# 这一个脚本里选,不用分别记好几个 curl 地址。选了之后委托给各自现有、已经
# 单独测过的 harbor-ctl.sh/devpi-ctl.sh/license-ctl.sh/license-deploy.sh,
# 这几个脚本本身没有任何改动,直接一行远程也照样能单独用。
#
# license-system 的镜像是私有仓库里的源码经 CI 编译推到 Harbor 的(不是像
# Harbor/devpi 那样拉官方现成镜像),但部署这个动作本身(拉镜像、起容器)不
# 涉及源码,所以 license-deploy.sh 依然可以放公开仓库、一行远程调用,不需要
# clone 私有的 license-system 仓库。
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
    echo "3) license 的 key 管理(签发/查询/吊销/恢复)"
    echo "4) license-system 部署/更新(拉Harbor镜像跑起来)"
    echo "0) 退出"
    echo "==============================================="
    read -r -p "请输入序号: " choice
    case "${choice}" in
      1) bash -c "$(curl -fsSL "${RAW_BASE}/harbor/harbor-ctl.sh")" ;;
      2) bash -c "$(curl -fsSL "${RAW_BASE}/devpi/devpi-ctl.sh")" ;;
      3) bash -c "$(curl -fsSL "${RAW_BASE}/license/license-ctl.sh")" ;;
      4) bash -c "$(curl -fsSL "${RAW_BASE}/license/license-deploy.sh")" ;;
      0) echo "退出。"; exit 0 ;;
      *) echo "无效选项,请重新输入。" ;;
    esac
  done
}

show_menu
