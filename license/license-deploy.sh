#!/usr/bin/env bash
# 部署/更新 license-system 这个服务本身(不是签发/管理key,那是同目录下的
# license-ctl.sh)。一行远程调用,不需要 clone 任何仓库——license-system 源码
# 是私有的,但这个脚本不含源码/密钥,只是拉 CI 已经构建好、推到 Harbor 的镜像
# 跑起来:
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/wyunsi280-cell/infra-deploy/main/license/license-deploy.sh)"
#
# 固定操作目录 LICENSE_HOME(默认 ~/infra/license-system),不管从哪里/怎么跑
# 这份脚本(本地clone、还是每次重新curl到/tmp),实际操作永远发生在这同一个
# 固定目录——跟 devpi-ctl.sh 的 DEVPI_HOME 是同一个道理,ADMIN_TOKEN 存在这个
# 目录的 .env 里,得跨次运行记住,不然每次重新curl一遍等于换了个空目录,
# 之前生成的 ADMIN_TOKEN 就"找不到"了(容器本身没事,数据卷还在,只是脚本
# 自己找不到本地这份配置)。

set -euo pipefail

LICENSE_HOME="${LICENSE_HOME:-${HOME}/infra/license-system}"
mkdir -p "${LICENSE_HOME}"
cd "${LICENSE_HOME}"

if ! docker info >/dev/null 2>&1; then
  echo "错误: 没有检测到 docker(或者没权限),先装好 docker 再跑本脚本。" >&2
  exit 1
fi

write_compose_file() {
  cat > docker-compose.deploy.yml << 'EOF'
services:
  license-system:
    image: ${HARBOR_REGISTRY:-harbor.touks.eu.org}/internal/license-system:latest
    environment:
      - ADMIN_TOKEN=${ADMIN_TOKEN:?需要设置 ADMIN_TOKEN 环境变量}
      - DB_PATH=/data/license.db
    volumes:
      - license-data:/data
    ports:
      - "8600:8600"
    restart: unless-stopped

volumes:
  license-data:
EOF
}

cmd_deploy() {
  write_compose_file

  local registry="${HARBOR_REGISTRY:-}"
  if [ -z "${registry}" ] && [ -t 0 ]; then
    read -r -p "Harbor 地址(直接回车用 harbor.touks.eu.org): " registry
  fi
  registry="${registry:-harbor.touks.eu.org}"

  local harbor_password="${HARBOR_PASSWORD:-}"
  if [ -z "${harbor_password}" ]; then
    if [ -t 0 ]; then
      read -r -s -p "Harbor 管理员密码: " harbor_password
      echo
    else
      echo "错误: 没有设置 HARBOR_PASSWORD,也没有终端可交互输入,没法登录 Harbor。" >&2
      exit 1
    fi
  fi
  echo "${harbor_password}" | docker login "${registry}" -u admin --password-stdin

  if [ ! -f .env ]; then
    echo "==> 没找到 .env(${LICENSE_HOME}/.env),当作第一次部署,生成 ADMIN_TOKEN"
    local admin_token
    admin_token="$(openssl rand -hex 16)"
    echo "ADMIN_TOKEN=${admin_token}" > .env
    echo "生成的 ADMIN_TOKEN(请当场保存,后面查不回来明文): ${admin_token}"
  else
    echo "==> 已有 .env(${LICENSE_HOME}/.env),复用里面的 ADMIN_TOKEN"
  fi

  echo "==> 拉取最新镜像(${registry}/internal/license-system:latest)"
  HARBOR_REGISTRY="${registry}" docker compose -f docker-compose.deploy.yml pull

  echo "==> 启动/更新容器"
  HARBOR_REGISTRY="${registry}" docker compose -f docker-compose.deploy.yml up -d

  echo ""
  echo "==================================================="
  echo "部署完成。操作目录: ${LICENSE_HOME}"
  echo "本机验证: curl -X POST http://localhost:8600/check -H 'Content-Type: application/json' -d '{\"key\":\"x\"}'"
  echo "公网域名验证: curl -X POST https://license.touks.eu.org/check -H 'Content-Type: application/json' -d '{\"key\":\"x\"}'"
  echo "==================================================="
}

cmd_status() {
  [ -f docker-compose.deploy.yml ] || write_compose_file
  docker compose -f docker-compose.deploy.yml ps
}

cmd_logs() {
  [ -f docker-compose.deploy.yml ] || write_compose_file
  docker compose -f docker-compose.deploy.yml logs --tail 50 -f
}

show_menu() {
  set +e
  while true; do
    echo ""
    echo "================ license-system 部署(${LICENSE_HOME}) ================"
    echo "1) 部署/更新(拉最新镜像并重启)"
    echo "2) 查看运行状态"
    echo "3) 查看日志(Ctrl+C 退出)"
    echo "0) 退出"
    echo "======================================================================"
    read -r -p "请输入序号: " choice
    case "${choice}" in
      1) cmd_deploy || echo "❌ 部署失败,请看上面的报错信息。" ;;
      2) cmd_status || echo "❌ 查询失败,请看上面的报错信息。" ;;
      3) cmd_logs ;;
      0) echo "退出。"; exit 0 ;;
      *) echo "无效选项,请重新输入。" ;;
    esac
  done
}

if [ $# -eq 0 ]; then
  if [ -t 0 ]; then
    show_menu
  else
    echo "错误: 没有交互终端(stdin 不是 tty),也没有传子命令,不能进菜单——" >&2
    echo "菜单靠 read 等键盘输入,非交互环境下 read 会一直读到 EOF,变成死循环。" >&2
    echo "用法: $0 [deploy|status|logs]" >&2
    exit 1
  fi
else
  case "$1" in
    deploy) cmd_deploy ;;
    status) cmd_status ;;
    logs) cmd_logs ;;
    *) echo "用法: $0 [deploy|status|logs]" >&2; exit 1 ;;
  esac
fi
