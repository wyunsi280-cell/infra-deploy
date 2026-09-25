#!/usr/bin/env bash
# devpi 管理脚本——私有 Python 包索引(devpi-server + Caddy 强制 Basic Auth)。
#
# 用法:直接运行,跟着菜单提示选择、按要求输入就行,不用记任何命令或参数。
#   ./devpi-ctl.sh

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

USERS_FILE="caddy/consumers.txt"

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

  echo "==================================================="
  echo " devpi 私有包索引 部署"
  echo "==================================================="

  read -r -p "设置 vendor 账号密码(用于 Basic Auth 网关 + devpi 上传权限,回车自动生成): " DEVPI_PASSWORD
  if [ -z "${DEVPI_PASSWORD}" ]; then
    DEVPI_PASSWORD="$(openssl rand -hex 12)"
    echo "自动生成的密码: ${DEVPI_PASSWORD}(请当场保存,后面查不回来明文)"
  fi

  read -r -p "对外访问的域名(比如 https://devpi.example.com,还没配好域名的话直接回车留空,只在内网用): " DEVPI_OUTSIDE_URL

  if [ -n "${DEVPI_OUTSIDE_URL}" ]; then
    PUBLIC_BASE="${DEVPI_OUTSIDE_URL}"
  else
    PUBLIC_BASE="http://localhost:3141"
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
  rm -f .env
  echo "==> 构建并启动容器(先不带外部域名,保证初始化阶段走纯内部地址)"
  docker compose up -d --build

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

  if [ -n "${DEVPI_OUTSIDE_URL}" ]; then
    echo "==> 补上外部域名配置,重启 devpi-server(数据已在卷里,不会重新初始化)"
    echo "DEVPI_OUTSIDE_URL=${DEVPI_OUTSIDE_URL}" > .env
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
  if [ -z "${DEVPI_OUTSIDE_URL}" ]; then
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
    echo "3) 添加只读协作者账号"
    echo "4) 查看所有账号"
    echo "5) 收回某个协作者账号"
    echo "0) 退出"
    echo "================================================="
    read -r -p "请输入序号: " choice
    case "${choice}" in
      1) cmd_install || echo "❌ 部署失败,请看上面的报错信息。" ;;
      2) cmd_status || echo "❌ 查询失败,请看上面的报错信息。" ;;
      3) cmd_consumer_add || echo "❌ 添加失败,请看上面的报错信息。" ;;
      4) cmd_consumer_list || echo "❌ 查询失败,请看上面的报错信息。" ;;
      5) cmd_consumer_remove || echo "❌ 收回失败,请看上面的报错信息。" ;;
      0) echo "退出。"; exit 0 ;;
      *) echo "无效选项,请重新输入。" ;;
    esac
  done
}

if [ $# -eq 0 ]; then
  require_docker
  show_menu
else
  require_docker
  case "$1" in
    install) cmd_install ;;
    status) cmd_status ;;
    consumer-add) shift; cmd_consumer_add "$@" ;;
    consumer-list) cmd_consumer_list ;;
    consumer-remove) shift; cmd_consumer_remove "$@" ;;
    *) echo "用法: $0 [install|status|consumer-add|consumer-list|consumer-remove]" >&2; exit 1 ;;
  esac
fi
