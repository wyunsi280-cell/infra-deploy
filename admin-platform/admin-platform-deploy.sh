#!/usr/bin/env bash
# 部署/更新 admin-platform 这个产品——一行远程调用,不需要 clone 任何仓库。
# 跟 license-deploy.sh 同一个模式,但这是**发给客户在客户自己服务器上跑**的
# (license-deploy.sh 只 vendor 自己用),所以:
#   - Harbor 用户名不写死 admin——客户应该用 Harbor 那边发的 robot 账号
#     (`robot$admin-platform+客户名` 这种),不该拿到 vendor 的管理员密码
#   - 镜像 tag 每次都要指定(不用 :latest)——不同客户可能停在不同版本,不想被
#     动到就不动,不像 license-system 只有 vendor 自己一份、永远追新版
#   - CORE_INSTANCE_KEY(license key)、DATABASES(客户自己的 Postgres 连接串)
#     这两个是必填的业务配置,不是基础设施密码,第一次部署会问,存进 .env,
#     以后 update 不用重新输入;改了要用菜单 5 单独更新
#   - 拉取镜像前强制验证 Cosign 签名(验不过直接拒绝部署,没有跳过选项)——
#     脚本里的 COSIGN_PUBLIC_KEY 需要换成 harbor-ctl.sh 菜单 8 生成的真实公钥,
#     还是占位内容的话验证会稳定失败(见脚本靠前位置的 COSIGN_PUBLIC_KEY)
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/wyunsi280-cell/infra-deploy/main/admin-platform/admin-platform-deploy.sh)"
#
# 固定操作目录 ADMIN_PLATFORM_HOME(默认 ~/infra/admin-platform),原因跟
# license-deploy.sh 的 LICENSE_HOME 一样:不管从哪里/怎么跑这份脚本,配置
# 都落在同一个固定目录,跨次运行才找得到。

set -euo pipefail

# 公钥可以公开,直接写死在这里——不是密码,不需要 secret。用 harbor-ctl.sh
# 菜单 8 生成密钥之后,把那次输出里的 cosign.pub 内容整段替换到这里。
# 占位内容原样保留的话,验证时会稳定失败(而不是悄悄跳过验证),提醒你还没换。
COSIGN_PUBLIC_KEY='-----BEGIN PUBLIC KEY-----
还没生成真实密钥——去 Harbor 服务器跑 harbor-ctl.sh 菜单 8,把输出的公钥内容
替换掉这整段占位文本(包括 BEGIN/END 这两行)。
-----END PUBLIC KEY-----'

ADMIN_PLATFORM_HOME="${ADMIN_PLATFORM_HOME:-${HOME}/infra/admin-platform}"
mkdir -p "${ADMIN_PLATFORM_HOME}"
cd "${ADMIN_PLATFORM_HOME}"

if ! docker info >/dev/null 2>&1; then
  echo "错误: 没有检测到 docker(或者没权限),先装好 docker 再跑本脚本。" >&2
  exit 1
fi

write_compose_file() {
  cat > docker-compose.deploy.yml << 'EOF'
services:
  admin-platform:
    image: ${HARBOR_REGISTRY:-harbor.touks.eu.org}/admin-platform/admin-platform:${IMAGE_TAG:?需要设置 IMAGE_TAG 环境变量,见 .env.deploy}
    env_file:
      - .env
    ports:
      - "${HOST_PORT:-8000}:8000"
    restart: unless-stopped
EOF
}

# docker compose 自己解析 compose 文件里的 ${IMAGE_TAG} 这类变量,靠的是
# --env-file(不是 env_file: 那个把变量传进*容器*的指令,是两回事)——只有
# cmd_deploy 那次调用手动 export 了 HARBOR_REGISTRY/IMAGE_TAG 不够,status/
# logs/uninstall 这些命令重新跑这份脚本时不会重新问一遍 tag,所以要把这两个
# 值也持久化,存在跟 .env(业务配置,会被 env_file 指令传进容器)分开的
# .env.deploy 里——避免 HARBOR_REGISTRY/IMAGE_TAG 这种部署元数据被当成应用
# 环境变量传进容器。
compose() {
  local env_file_args=()
  [ -f .env.deploy ] && env_file_args=(--env-file .env.deploy)
  docker compose "${env_file_args[@]}" -f docker-compose.deploy.yml "$@"
}

ensure_cosign_cli() {
  if command -v cosign >/dev/null 2>&1; then
    return
  fi
  echo "==> 没检测到 cosign 命令行工具,下载一份到 ${ADMIN_PLATFORM_HOME}"
  curl -sL -o cosign "https://github.com/sigstore/cosign/releases/latest/download/cosign-linux-amd64"
  chmod +x cosign
  COSIGN_BIN="./cosign"
}
COSIGN_BIN="cosign"

# 验证不过直接 exit,不给"跳过验证继续部署"这个选项——镜像来源没验证过就不
# 该跑在客户机器上,这一步不是可选的安全建议,是强制拦截。
verify_image_signature() {
  local image_ref="$1"
  ensure_cosign_cli
  echo "==> 验证镜像签名(Cosign): ${image_ref}"
  if ! "${COSIGN_BIN}" verify --key <(printf '%s' "${COSIGN_PUBLIC_KEY}") "${image_ref}" >/dev/null 2>&1; then
    echo "错误: 镜像签名验证失败——${image_ref} 不是用受信任的私钥签的,或者" >&2
    echo "  ${ADMIN_PLATFORM_HOME}/admin-platform-deploy.sh 里的 COSIGN_PUBLIC_KEY 还是占位内容没换。" >&2
    echo "  拒绝部署,不会拉取/启动这个镜像。" >&2
    exit 1
  fi
  echo "==> 签名验证通过"
}

_prompt_required() {
  # $1=提示语 $2=变量名(用来判断是不是已经通过环境变量传进来了)
  local prompt="$1" varname="$2" value=""
  eval "value=\"\${${varname}:-}\""
  if [ -z "${value}" ]; then
    if [ -t 0 ]; then
      read -r -p "${prompt}: " value
    else
      echo "错误: 没有设置 ${varname},也没有终端可交互输入。" >&2
      exit 1
    fi
  fi
  printf '%s' "${value}"
}

cmd_deploy() {
  local registry="${HARBOR_REGISTRY:-}"
  if [ -z "${registry}" ] && [ -t 0 ]; then
    read -r -p "Harbor 地址(直接回车用 harbor.touks.eu.org): " registry
  fi
  registry="${registry:-harbor.touks.eu.org}"

  local harbor_user="${HARBOR_USER:-}"
  if [ -z "${harbor_user}" ] && [ -t 0 ]; then
    read -r -p "Harbor 用户名(客户部署用 robot\$admin-platform+客户名 这种,不要用 admin): " harbor_user
  fi
  if [ -z "${harbor_user}" ]; then
    echo "错误: 没有设置 HARBOR_USER。" >&2
    exit 1
  fi

  local harbor_password="${HARBOR_PASSWORD:-}"
  if [ -z "${harbor_password}" ]; then
    if [ -t 0 ]; then
      read -r -s -p "Harbor 密码/robot secret: " harbor_password
      echo
    else
      echo "错误: 没有设置 HARBOR_PASSWORD,也没有终端可交互输入,没法登录 Harbor。" >&2
      exit 1
    fi
  fi
  echo "${harbor_password}" | docker login "${registry}" -u "${harbor_user}" --password-stdin

  local image_tag
  image_tag="$(_prompt_required "镜像 tag(比如 v0.1.1,发布时 build-and-publish.sh 打的那个)" IMAGE_TAG)"

  verify_image_signature "${registry}/admin-platform/admin-platform:${image_tag}"

  if [ ! -f .env ]; then
    echo "==> 没找到 .env(${ADMIN_PLATFORM_HOME}/.env),当作第一次部署,收集应用配置"
    local instance_key databases redis_conf
    instance_key="$(_prompt_required "CORE_INSTANCE_KEY(license-ctl.sh 签发给这个客户的 key,一整串)" CORE_INSTANCE_KEY)"
    databases="$(_prompt_required '数据库连接串,DATABASES 环境变量的值,形如 {"default": "postgresql+asyncpg://user:pass@host/db"}' DATABASES)"
    redis_conf="${REDIS:-}"
    if [ -z "${redis_conf}" ] && [ -t 0 ]; then
      read -r -p "Redis 连接串(没有直接回车跳过,REDIS 环境变量的值,形如 {\"cache\": \"redis://host:6379/0\"}): " redis_conf
    fi
    {
      echo "CORE_INSTANCE_KEY=${instance_key}"
      echo "DATABASES=${databases}"
      echo "REDIS=${redis_conf:-{\}}"
    } > .env
    echo "==> 已生成 ${ADMIN_PLATFORM_HOME}/.env"
  else
    echo "==> 已有 .env(${ADMIN_PLATFORM_HOME}/.env),复用里面的应用配置(license key/数据库连接串没变的话不用管)"
  fi

  write_compose_file
  {
    echo "HARBOR_REGISTRY=${registry}"
    echo "IMAGE_TAG=${image_tag}"
  } > .env.deploy

  echo "==> 拉取镜像(${registry}/admin-platform/admin-platform:${image_tag})"
  compose pull

  echo "==> 启动/更新容器"
  compose up -d

  echo ""
  echo "==================================================="
  echo "部署完成。操作目录: ${ADMIN_PLATFORM_HOME}"
  echo "本机验证: curl localhost:${HOST_PORT:-8000}/"
  echo "(license key 校验没过的话容器会直接退出,看不到端口监听——用菜单 3 看日志排查)"
  echo "==================================================="
}

cmd_update_app_config() {
  [ -f .env ] || { echo "还没部署过,先跑菜单 1。" >&2; return 1; }

  # 用 grep/cut 纯文本提取,不用 sed 替换/不 source 这个文件——DATABASES/REDIS
  # 的值是 JSON,常见 postgresql://...?ssl=true&timeout=5 这种带 & 的连接串,
  # & 在 sed 替换文本里是"整个匹配串"的特殊字符,直接替换会把值搅乱;这个值
  # 也可能含 & 导致 source/bash 当命令解释(& 会被当成后台运行),所以只用
  # grep/cut 读、echo 写,全程不让这段文本被 shell/sed 当语法解析。
  local cur_key cur_databases cur_redis
  cur_key="$(grep -m1 '^CORE_INSTANCE_KEY=' .env | cut -d= -f2-)"
  cur_databases="$(grep -m1 '^DATABASES=' .env | cut -d= -f2-)"
  cur_redis="$(grep -m1 '^REDIS=' .env | cut -d= -f2-)"

  echo "当前配置(license key 只显示前后各6位):"
  echo "CORE_INSTANCE_KEY=${cur_key:0:6}...${cur_key: -6}"
  echo "DATABASES=${cur_databases}"
  echo "REDIS=${cur_redis}"
  echo ""

  # 非交互场景(比如自动化脚本调这个子命令)靠 NEW_* 环境变量传新值,不设的话
  # 保留现有值,不会像其它必填项那样报错退出——"什么都不传"对"更新配置"这个
  # 操作来说是合法输入(就是不改)。
  local instance_key="${NEW_CORE_INSTANCE_KEY:-}" databases="${NEW_DATABASES:-}" redis_conf="${NEW_REDIS:-}"
  if [ -t 0 ]; then
    [ -z "${instance_key}" ] && read -r -p "新的 CORE_INSTANCE_KEY(直接回车保留现有的): " instance_key
    [ -z "${databases}" ] && read -r -p "新的 DATABASES(直接回车保留现有的): " databases
    [ -z "${redis_conf}" ] && read -r -p "新的 REDIS(直接回车保留现有的): " redis_conf
  fi

  {
    echo "CORE_INSTANCE_KEY=${instance_key:-${cur_key}}"
    echo "DATABASES=${databases:-${cur_databases}}"
    echo "REDIS=${redis_conf:-${cur_redis}}"
  } > .env

  echo "==> 配置已更新,重启容器生效"
  [ -f docker-compose.deploy.yml ] || write_compose_file
  compose up -d
}

cmd_status() {
  [ -f docker-compose.deploy.yml ] || write_compose_file
  compose ps
}

cmd_logs() {
  [ -f docker-compose.deploy.yml ] || write_compose_file
  compose logs --tail 50 -f
}

cmd_uninstall() {
  echo "警告:此操作会永久删除这套 admin-platform(${ADMIN_PLATFORM_HOME})的容器——"
  echo "license key、数据库连接串这些配置(.env)也会一起删掉,不可恢复!"
  echo "(数据库本身不在这个目录里,不受影响——这里删的只是这个应用容器的配置)"
  echo ""
  read -r -p "确认继续吗?输入大写 DELETE 继续,其他任意输入取消: " confirm1
  if [ "${confirm1}" != "DELETE" ]; then
    echo "已取消,没有做任何改动。"
    return
  fi

  echo ""
  read -r -p "最后确认:真的要卸载吗?输入 yes 继续: " confirm2
  if [ "${confirm2}" != "yes" ]; then
    echo "已取消,没有做任何改动。"
    return
  fi

  [ -f docker-compose.deploy.yml ] || write_compose_file
  echo "==> 停止并删除容器"
  compose down 2>/dev/null || true

  echo "==> 删除操作目录 ${ADMIN_PLATFORM_HOME}"
  local target="${ADMIN_PLATFORM_HOME}"
  cd /
  rm -rf "${target}"

  echo "已卸载。要重新部署,直接再跑一遍这份脚本、选 1 就行。"
}

show_menu() {
  set +e
  while true; do
    echo ""
    echo "================ admin-platform 部署(${ADMIN_PLATFORM_HOME}) ================"
    echo "1) 部署/更新(拉指定 tag 镜像并重启,第一次跑会问 license key/数据库配置)"
    echo "2) 查看运行状态"
    echo "3) 查看日志(Ctrl+C 退出)"
    echo "4) 卸载(危险操作,不可恢复,会多次确认)"
    echo "5) 更新应用配置(license key 换了 / 数据库连接串改了 用这个,不用重新拉镜像)"
    echo "0) 退出"
    echo "==========================================================================="
    read -r -p "请输入序号: " choice
    case "${choice}" in
      1) cmd_deploy || echo "❌ 部署失败,请看上面的报错信息。" ;;
      2) cmd_status || echo "❌ 查询失败,请看上面的报错信息。" ;;
      3) cmd_logs ;;
      4) cmd_uninstall || echo "❌ 卸载失败,请看上面的报错信息。" ;;
      5) cmd_update_app_config || echo "❌ 更新配置失败,请看上面的报错信息。" ;;
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
    echo "用法: $0 [deploy|status|logs|update-config|uninstall]" >&2
    exit 1
  fi
else
  case "$1" in
    deploy) cmd_deploy ;;
    status) cmd_status ;;
    logs) cmd_logs ;;
    update-config) cmd_update_app_config ;;
    uninstall) cmd_uninstall ;;
    *) echo "用法: $0 [deploy|status|logs|update-config|uninstall]" >&2; exit 1 ;;
  esac
fi
