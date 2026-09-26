#!/usr/bin/env bash
# devpi 管理脚本——私有 Python 包索引(devpi-server + Caddy 强制 Basic Auth)。
#
# 一行远程用(跟 harbor-ctl.sh 一样,不用先 clone 仓库):
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/wyunsi280-cell/infra-deploy/main/devpi/devpi-ctl.sh)"
# 不加任何参数直接弹菜单。也支持命令行子命令模式,见文件末尾。
#
# 不管这份脚本本身是从哪里、被怎么运行的(本地 clone、还是每次重新 curl 到
# /tmp),实际操作都固定发生在 DEVPI_HOME 这个目录——协作者账号列表这些需要
# 跨次运行记住的状态,不能跟着"脚本文件当前放在哪"到处漂移,不然每次重新
# curl 一遍就等于换了个全新的空目录,之前加的账号全"找不到"了(其实是登记
# 的文件没了,不是账号真的丢了)。跟 Harbor 的差别是:Harbor 的账号数据存在
# Harbor 服务器自己的数据库里,客户端脚本本来就不需要记什么状态;devpi 的
# 协作者账号是存在 Caddy 的 Basic Auth 文件里,这个文件必须要有一个固定的家。
set -euo pipefail

DEVPI_HOME="${DEVPI_HOME:-${HOME}/infra/devpi}"
RAW_BASE="https://raw.githubusercontent.com/wyunsi280-cell/infra-deploy/main/devpi"
USERS_FILE="caddy/consumers.txt"

# 想在同一台机器上并排跑第二套(比如测试环境),这两个变量分开传:
#   DEVPI_HOME=~/infra/devpi-test COMPOSE_PROJECT_NAME=devpi-test DEVPI_HOST_PORT=3142 \
#     bash -c "$(curl -fsSL .../devpi-ctl.sh)"
# COMPOSE_PROJECT_NAME 决定容器叫什么名字(devpi-devpi-1 还是 devpi-test-devpi-1),
# 不显式设的话两套装在不同目录也可能因为 docker compose 自动推导出一样的
# 项目名而互相打架,所以固定下来,不依赖自动推导。
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-devpi}"
export COMPOSE_PROJECT_NAME

# install 需要这几个文件跟自己在同一个目录才能当 docker compose 的 build
# context 用;不存在就现场拉一份(已存在的不覆盖,免得覆盖掉你自己改过的)。
fetch_support_files() {
  mkdir -p "${DEVPI_HOME}"
  cd "${DEVPI_HOME}"
  local f
  for f in Dockerfile entrypoint.sh docker-compose.yml; do
    if [ ! -f "${f}" ]; then
      curl -fsSL "${RAW_BASE}/${f}" -o "${f}"
    fi
  done
  chmod +x entrypoint.sh 2>/dev/null || true
}

require_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "错误: 没有检测到 Docker,先装好 Docker(和 docker compose 插件)再跑本脚本。" >&2
    exit 1
  fi
  if ! docker info >/dev/null 2>&1; then
    echo "错误: 当前用户跑不动 docker(通常是没在 docker 用户组里)。" >&2
    echo "  用 root 跑本脚本,或者 sudo usermod -aG docker \$USER 之后重新登录一次再跑。" >&2
    exit 1
  fi
  if ! docker compose version >/dev/null 2>&1; then
    echo "错误: 没有 docker compose 插件,请检查 Docker 安装是否完整" >&2
    exit 1
  fi
}

get_vendor_hash() {
  awk '$1 == "vendor" {print $2}' caddy/Caddyfile 2>/dev/null | head -1
}

# 跟 harbor-ctl.sh 的 get_core_env 一个道理:密码存在容器环境变量里,不用
# 另外存一份明文文件,要查的时候现读。
get_vendor_password() {
  docker inspect "${COMPOSE_PROJECT_NAME}-devpi-1" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
    | grep '^DEVPI_PASSWORD=' | head -1 | cut -d= -f2-
}

regen_caddyfile() {
  local vendor_hash
  vendor_hash="$(get_vendor_hash)"
  touch "${USERS_FILE}"
  {
    echo ":3141 {"
    echo "	basic_auth {"
    echo "		vendor ${vendor_hash}"
    local _line_name _line_hash
    while IFS=: read -r _line_name _line_hash; do
      [ -z "${_line_name}" ] && continue
      echo "		${_line_name} ${_line_hash}"
    done < "${USERS_FILE}"
    echo "	}"
    echo "	reverse_proxy devpi:3141"
    echo "}"
  } > caddy/Caddyfile
  docker compose restart caddy >/dev/null
}

cmd_install() {
  require_docker
  fetch_support_files

  echo "==================================================="
  echo " devpi 私有包索引 部署"
  echo "==================================================="

  # 优先级:环境变量传入 > 交互式手动输入(仅当 stdin 是真终端时)> 自动生成/留空。
  # `curl | bash` 这种管道运行方式下 stdin 已经被脚本内容本身占用,不是终端,
  # 这时候 `read` 会立刻碰到 EOF 返回失败,配合 `set -e` 会导致脚本静默退出
  # (跟 harbor-ctl.sh 保持一致的判断方式,一行安装才不会被这里絆倒)。
  if [ -z "${DEVPI_PASSWORD:-}" ]; then
    if [ -t 0 ]; then
      read -r -p "设置 vendor 账号密码(用于 Basic Auth 网关 + devpi 上传权限,回车自动生成): " DEVPI_PASSWORD
    fi
    if [ -z "${DEVPI_PASSWORD:-}" ]; then
      DEVPI_PASSWORD="$(openssl rand -hex 12)"
      echo "自动生成的密码: ${DEVPI_PASSWORD}(请当场保存,后面查不回来明文)"
    fi
  fi
  # 存进容器环境变量里(docker-compose.yml 里已声明 DEVPI_PASSWORD),
  # 跟 harbor-ctl.sh 读 harbor-core 的 HARBOR_ADMIN_PASSWORD 是一个道理——
  # 以后要查/要用这个密码,不用再问人,`docker inspect devpi-devpi-1` 就能拿到,
  # 不用另外存一份明文文件。
  export DEVPI_PASSWORD

  if [ -z "${DEVPI_OUTSIDE_URL:-}" ] && [ -t 0 ]; then
    read -r -p "对外访问的域名(比如 https://devpi.example.com,还没配好域名的话直接回车留空,只在内网用): " DEVPI_OUTSIDE_URL
  fi

  if [ -z "${DEVPI_HOST_PORT:-}" ] && [ -t 0 ]; then
    read -r -p "对外暴露的端口(同一台机器上要跑第二套(比如测试环境)才需要改,直接回车用 3141): " DEVPI_HOST_PORT
  fi
  DEVPI_HOST_PORT="${DEVPI_HOST_PORT:-3141}"
  export DEVPI_HOST_PORT

  if [ -n "${DEVPI_OUTSIDE_URL:-}" ]; then
    PUBLIC_BASE="${DEVPI_OUTSIDE_URL}"
  else
    PUBLIC_BASE="http://localhost:${DEVPI_HOST_PORT}"
  fi

  echo "==> 生成 Caddy Basic Auth 密码哈希"
  mkdir -p caddy
  touch "${USERS_FILE}"
  local hash
  hash="$(docker run --rm caddy:2-alpine caddy hash-password --plaintext "${DEVPI_PASSWORD}")"
  cat > caddy/Caddyfile << EOF
:3141 {
	basic_auth {
		vendor ${hash}
	}
	reverse_proxy devpi:3141
}
EOF

  # 先不带 --outside-url 起一次:一旦设了 outside-url,devpi-server 的 +api
  # 自报地址就会变成外部域名,容器内部用 localhost 做 devpi use/login 这些初始化
  # 操作会被带飞到外部域名上去(还没配凭证,直接 401)。所以初始化阶段必须用
  # "干净"的内部地址,建完 root/vendor/prod 这些之后,再补上 outside-url 重启一次
  # ——数据在卷里,重启不会重新初始化,只是让 devpi-server 换个自报地址。
  #
  # 注意:docker compose 会直接读父进程环境变量里的 DEVPI_OUTSIDE_URL(不止是
  # .env 文件),如果调用方是 `export DEVPI_OUTSIDE_URL=... 后 curl|bash` 这种
  # 用法,这里不显式清空的话,第一次 up 照样会把它带进去,等于没修。
  # DEVPI_HOST_PORT 一直写进 .env(不像 DEVPI_OUTSIDE_URL 那样要分两阶段),
  # 不然以后重跑 install(比如只是想补个域名)又没重新传 DEVPI_HOST_PORT 的话,
  # 会悄悄变回默认的 3141,跟同一台机器上跑的另一套(比如生产那套)抢端口。
  echo "DEVPI_HOST_PORT=${DEVPI_HOST_PORT}" > .env
  echo "==> 构建并启动容器(先不带外部域名,保证初始化阶段走纯内部地址)"
  DEVPI_OUTSIDE_URL= docker compose up -d --build

  echo "==> 等待 devpi-server 就绪"
  local i
  for i in $(seq 1 30); do
    if docker compose exec -T devpi python3 -c "import urllib.request; urllib.request.urlopen('http://localhost:3141/root/pypi/')" >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done

  echo "==> 初始化 root 密码 + 创建 vendor 用户/索引(已存在则跳过)"
  docker compose exec -T devpi devpi use http://localhost:3141 >/dev/null
  docker compose exec -T devpi devpi login root --password "" >/dev/null 2>&1 || true
  docker compose exec -T devpi devpi user -m root "password=${DEVPI_PASSWORD}" >/dev/null 2>&1 || true
  docker compose exec -T devpi devpi login root --password "${DEVPI_PASSWORD}" >/dev/null
  if ! docker compose exec -T devpi devpi user -l 2>/dev/null | grep -q '^vendor$'; then
    docker compose exec -T devpi devpi user -c vendor "password=${DEVPI_PASSWORD}" email=vendor@example.com >/dev/null
  fi
  docker compose exec -T devpi devpi login vendor --password "${DEVPI_PASSWORD}" >/dev/null
  docker compose exec -T devpi devpi index -c prod bases=root/pypi >/dev/null 2>&1 || true

  if [ -n "${DEVPI_OUTSIDE_URL:-}" ]; then
    echo "==> 补上外部域名配置,重启 devpi-server(数据已在卷里,不会重新初始化)"
    {
      echo "DEVPI_HOST_PORT=${DEVPI_HOST_PORT}"
      echo "DEVPI_OUTSIDE_URL=${DEVPI_OUTSIDE_URL}"
    } > .env
    docker compose up -d
  fi

  local scheme host
  scheme="${PUBLIC_BASE%%://*}"
  host="${PUBLIC_BASE#*://}"

  echo ""
  echo "==================================================="
  echo "部署完成"
  echo "地址: ${PUBLIC_BASE}/vendor/prod/"
  echo "账号: vendor"
  echo "密码: ${DEVPI_PASSWORD}"
  echo ""
  echo "上传(在项目目录下,先 uv build 出 wheel):"
  echo "  devpi use ${scheme}://vendor:${DEVPI_PASSWORD}@${host}/vendor/prod"
  echo "  devpi upload dist/*.whl"
  echo ""
  echo "消费方 pyproject.toml 加索引(账号密码不要写进去,用环境变量传,见 devpi/README.md):"
  echo "  [[tool.uv.index]]"
  echo "  name = \"internal\""
  echo "  url = \"${PUBLIC_BASE}/vendor/prod/+simple/\""
  if [ -z "${DEVPI_OUTSIDE_URL:-}" ]; then
    echo ""
    echo "现在只在内网用,以后要接 GitHub Actions 之类的云端 CI,得先给这台机器配一个"
    echo "公网能访问的域名(跟 Harbor 当初配 Cloudflare 隧道一样),然后重新跑一遍本脚本"
    echo "并在提示时填那个域名——devpi-server 需要知道自己对外的真实地址才能正确处理"
    echo "登录/上传请求,不是配好域名转发就行。"
  fi
  echo "==================================================="
}

cmd_status() {
  docker compose ps
}

cmd_credentials() {
  local password
  password="$(get_vendor_password)"
  if [ -z "${password}" ]; then
    echo "查不到密码——devpi 容器没在跑,或者是老版本装的(那时候还没把密码存进容器环境变量),重新跑一遍安装即可。" >&2
    return 1
  fi
  echo "账号: vendor"
  echo "密码: ${password}"
}

cmd_create_index() {
  local index_name="${1:-}"
  if [ -z "${index_name}" ]; then
    read -r -p "新建索引名(比如 test,不确定要不要就直接想想名字,不要跟 prod 重了): " index_name
  fi
  [ -z "${index_name}" ] && { echo "取消。"; return; }

  local password
  password="$(get_vendor_password)"
  if [ -z "${password}" ]; then
    echo "查不到 vendor 密码——devpi 容器没在跑?" >&2
    return 1
  fi

  # 账号密码直接嵌进 devpi use 的 URL——这台 devpi 已经配了 --outside-url,
  # 裸的 `devpi use http://localhost:3141` 会被 +api 探测带到外部域名上,
  # 内部命令没带凭证就会 401(cmd_install 那边也踩过同一个坑,是同一个原因)。
  docker compose exec -T devpi devpi use "http://vendor:${password}@localhost:3141" >/dev/null
  docker compose exec -T devpi devpi login vendor --password "${password}" >/dev/null
  if docker compose exec -T devpi devpi index vendor/"${index_name}" >/dev/null 2>&1; then
    echo "vendor/${index_name} 已经存在了,不用重建。"
    return
  fi
  docker compose exec -T devpi devpi index -c "${index_name}" bases=root/pypi >/dev/null
  echo "已创建索引: vendor/${index_name}"
  echo "跟 vendor/prod 是同一个 vendor 账号密码,只是索引名不一样——发布/消费的时候把 URL 里的 prod 换成 ${index_name} 就行。"
}

cmd_consumer_add() {
  local name="${1:-}" password="${2:-}"
  if [ -z "${name}" ]; then
    read -r -p "协作者/CI 名字(只读,能pip装包,不能上传): " name
  fi
  [ -z "${name}" ] && { echo "取消。"; return; }
  if [ -z "${password}" ]; then
    password="$(openssl rand -hex 12)"
  fi
  local hash
  hash="$(docker run --rm caddy:2-alpine caddy hash-password --plaintext "${password}")"
  touch "${USERS_FILE}"
  grep -v "^${name}:" "${USERS_FILE}" > "${USERS_FILE}.tmp" 2>/dev/null || true
  mv "${USERS_FILE}.tmp" "${USERS_FILE}"
  echo "${name}:${hash}" >> "${USERS_FILE}"
  regen_caddyfile
  echo "已添加只读账号: ${name}"
  echo "密码: ${password}(请当场保存,后面查不回来明文)"
}

cmd_consumer_list() {
  echo "vendor(读+传)"
  touch "${USERS_FILE}"
  cut -d: -f1 "${USERS_FILE}" | sed 's/^/  /; s/$/(只读)/'
}

cmd_consumer_remove() {
  local name="${1:-}"
  if [ -z "${name}" ]; then
    cmd_consumer_list
    read -r -p "输入要收回的名字(直接回车取消): " name
  fi
  [ -z "${name}" ] && { echo "取消。"; return; }
  touch "${USERS_FILE}"
  grep -v "^${name}:" "${USERS_FILE}" > "${USERS_FILE}.tmp" 2>/dev/null || true
  mv "${USERS_FILE}.tmp" "${USERS_FILE}"
  regen_caddyfile
  echo "已收回: ${name}(立即生效,不影响 vendor 和其他账号)"
}

show_menu() {
  set +e
  while true; do
    echo ""
    echo "================ devpi 管理工具 ================"
    echo "1) 安装部署"
    echo "2) 查看运行状态"
    echo "3) 查看 vendor 账号密码"
    echo "4) 添加只读协作者账号"
    echo "5) 查看所有账号"
    echo "6) 收回某个协作者账号"
    echo "7) 创建额外索引(比如测试用的 test,不用重新装一套)"
    echo "0) 退出"
    echo "================================================="
    read -r -p "请输入序号: " choice
    case "${choice}" in
      1) cmd_install || echo "❌ 部署失败,请看上面的报错信息。" ;;
      2) cmd_status || echo "❌ 查询失败,请看上面的报错信息。" ;;
      3) cmd_credentials || echo "❌ 查询失败,请看上面的报错信息。" ;;
      4) cmd_consumer_add || echo "❌ 添加失败,请看上面的报错信息。" ;;
      5) cmd_consumer_list || echo "❌ 查询失败,请看上面的报错信息。" ;;
      6) cmd_consumer_remove || echo "❌ 收回失败,请看上面的报错信息。" ;;
      7) cmd_create_index || echo "❌ 创建失败,请看上面的报错信息。" ;;
      0) echo "退出。"; exit 0 ;;
      *) echo "无效选项,请重新输入。" ;;
    esac
  done
}

mkdir -p "${DEVPI_HOME}"
cd "${DEVPI_HOME}"

if [ $# -eq 0 ]; then
  require_docker
  show_menu
else
  require_docker
  case "$1" in
    install) cmd_install ;;
    status) cmd_status ;;
    credentials) cmd_credentials ;;
    consumer-add) shift; cmd_consumer_add "$@" ;;
    consumer-list) cmd_consumer_list ;;
    consumer-remove) shift; cmd_consumer_remove "$@" ;;
    create-index) shift; cmd_create_index "$@" ;;
    *) echo "用法: $0 [install|status|credentials|consumer-add|consumer-list|consumer-remove|create-index]" >&2; exit 1 ;;
  esac
fi
