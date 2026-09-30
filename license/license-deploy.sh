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
#
# 拉取镜像前强制验证 Cosign 签名(验不过直接拒绝部署,没有跳过选项)——公钥
# 写死在脚本靠前位置的 COSIGN_PUBLIC_KEY,跟 admin-platform 用同一套密钥。

set -euo pipefail

# 公钥可以公开,直接写死在这里——不是密码,不需要 secret。跟 admin-platform
# 用同一套密钥(同一个 Harbor,同一个信任根),harbor-ctl.sh 菜单 8 生成。
COSIGN_PUBLIC_KEY='-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE3IHNaobxtYQKeaUPDBkj3WilcAnL
rBZ8vS394xW7EZ6O+pcWxV8Ku1r/IQ0pw9I5tLHvySB5CvkOQ3XiQwivCw==
-----END PUBLIC KEY-----'

ensure_cosign_cli() {
  if command -v cosign >/dev/null 2>&1; then
    COSIGN_BIN=cosign
    return
  fi
  echo "==> 没检测到 cosign 命令行工具,下载一份到 ${LICENSE_HOME}"
  curl -sL -o cosign "https://github.com/sigstore/cosign/releases/latest/download/cosign-linux-amd64"
  chmod +x cosign
  COSIGN_BIN="./cosign"
}

# 验证不过直接 exit,不给"跳过验证继续部署"这个选项——原因跟
# admin-platform-deploy.sh 一样:这不是可选的安全建议,是强制拦截。
verify_image_signature() {
  local image_ref="$1"
  ensure_cosign_cli
  echo "==> 验证镜像签名(Cosign): ${image_ref}"
  if ! "${COSIGN_BIN}" verify --key <(printf '%s' "${COSIGN_PUBLIC_KEY}") "${image_ref}" >/dev/null 2>&1; then
    echo "错误: 镜像签名验证失败——${image_ref} 不是用受信任的私钥签的。拒绝部署。" >&2
    exit 1
  fi
  echo "==> 签名验证通过"
}

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

  verify_image_signature "${registry}/internal/license-system:latest"

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

cmd_uninstall() {
  echo "警告:此操作会永久删除这套 license-system(${LICENSE_HOME})的容器、数据卷——"
  echo "已签发的所有 key、私钥、ADMIN_TOKEN 全部丢失,不可恢复!"
  echo "私钥丢失还有连带影响:重装后会生成新私钥,fastapi_admin_core 里编译进去的"
  echo "公钥常量要跟着更新,不然客户端本地验签会全部失败(这个坑已经真实踩过)。"
  echo ""
  read -r -p "确认继续吗?输入大写 DELETE 继续,其他任意输入取消: " confirm1
  if [ "${confirm1}" != "DELETE" ]; then
    echo "已取消,没有做任何改动。"
    return
  fi

  echo ""
  echo "最后确认:这会清空 ${LICENSE_HOME} 里的全部数据,无法恢复。"
  read -r -p "真的要卸载吗?输入 yes 继续: " confirm2
  if [ "${confirm2}" != "yes" ]; then
    echo "已取消,没有做任何改动。"
    return
  fi

  [ -f docker-compose.deploy.yml ] || write_compose_file
  echo "==> 停止并删除容器、数据卷"
  docker compose -f docker-compose.deploy.yml down -v 2>/dev/null || true

  echo "==> 删除操作目录 ${LICENSE_HOME}"
  local target="${LICENSE_HOME}"
  cd /
  rm -rf "${target}"

  echo "已卸载。要重新部署,直接再跑一遍这份脚本、选 1 就行(会当成第一次部署,生成新的 ADMIN_TOKEN 和新的签名密钥)。"
}

show_menu() {
  set +e
  while true; do
    echo ""
    echo "================ license-system 部署(${LICENSE_HOME}) ================"
    echo "1) 部署/更新(拉最新镜像并重启)"
    echo "2) 查看运行状态"
    echo "3) 查看日志(Ctrl+C 退出)"
    echo "4) 卸载(危险操作,不可恢复,会多次确认)"
    echo "0) 退出"
    echo "======================================================================"
    read -r -p "请输入序号: " choice
    case "${choice}" in
      1) cmd_deploy || echo "❌ 部署失败,请看上面的报错信息。" ;;
      2) cmd_status || echo "❌ 查询失败,请看上面的报错信息。" ;;
      3) cmd_logs ;;
      4) cmd_uninstall || echo "❌ 卸载失败,请看上面的报错信息。" ;;
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
    echo "用法: $0 [deploy|status|logs|uninstall]" >&2
    exit 1
  fi
else
  case "$1" in
    deploy) cmd_deploy ;;
    status) cmd_status ;;
    logs) cmd_logs ;;
    uninstall) cmd_uninstall ;;
    *) echo "用法: $0 [deploy|status|logs|uninstall]" >&2; exit 1 ;;
  esac
fi
