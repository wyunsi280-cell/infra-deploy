#!/usr/bin/env bash
# Harbor 管理脚本
#
# 用法:直接运行,跟着菜单提示选择、按要求输入就行,不用记任何命令或参数。
#   ./harbor-ctl.sh
#
# (给自动化脚本用的命令行子命令模式也保留在代码里,不是本脚本的主要用法,
#  详见 show_menu 下面的 case 分支,这里不展开。)

set -euo pipefail

if ! command -v docker >/dev/null 2>&1; then
  echo "错误: 没有检测到 Docker,先装好 Docker(和 docker compose 插件)再跑本脚本。" >&2
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "错误: 当前用户跑不动 docker(通常是没在 docker 用户组里)。" >&2
  echo "  用 root 跑本脚本,或者 sudo usermod -aG docker \$USER 之后重新登录一次再跑。" >&2
  exit 1
fi

HARBOR_VERSION="${HARBOR_VERSION:-v2.15.2}"
INSTALL_DIR="${HARBOR_INSTALL_DIR:-$HOME/harbor-install}"
HARBOR_DIR="${INSTALL_DIR}/harbor"

usage() {
  sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
}

# 从运行中的 harbor-core 容器读取 EXT_ENDPOINT / 管理员密码,不落盘存储
get_core_env() {
  local key="$1"
  docker inspect harbor-core --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
    | grep "^${key}=" | head -1 | cut -d= -f2-
}

require_running() {
  if ! docker ps --format '{{.Names}}' | grep -qx harbor-core; then
    echo "错误: harbor-core 容器没有在运行,先执行 install 或检查部署状态" >&2
    exit 1
  fi
}

# 按项目名查数字 project_id —— Harbor 的 robot 列表接口要求按 ProjectID 过滤,不接受项目名
get_project_id() {
  local ext_endpoint="$1" password="$2" project="$3"
  curl -sf -u "admin:${password}" "${ext_endpoint}/api/v2.0/projects?name=${project}" \
    | grep -o '"project_id":[0-9]*' | head -1 | cut -d: -f2
}

cmd_install() {
  local hostname_value="${HARBOR_HOSTNAME:-}"
  local http_port="${HARBOR_HTTP_PORT:-}"

  # 没有预先传环境变量、且是交互式运行(走菜单)时,直接问,不用记环境变量语法
  if [ -z "${hostname_value}" ]; then
    if [ -t 0 ]; then
      read -r -p "对外访问的域名或IP(直接回车用 localhost,仅本机测试用): " hostname_value
      hostname_value="${hostname_value:-localhost}"
    else
      hostname_value="localhost"
    fi
  fi
  if [ -z "${http_port}" ]; then
    if [ -t 0 ]; then
      read -r -p "对外访问端口(直接回车用 8090): " http_port
      http_port="${http_port:-8090}"
    else
      http_port="8090"
    fi
  fi

  # 密码优先级:环境变量传入 > 交互式手动输入 > 自动生成随机密码,不用固定默认密码
  local admin_password generated_password=0
  if [ -n "${HARBOR_ADMIN_PASSWORD:-}" ]; then
    admin_password="${HARBOR_ADMIN_PASSWORD}"
  elif [ -t 0 ]; then
    read -r -s -p "设置 Harbor 管理员密码(直接回车则自动生成随机密码): " admin_password
    echo
    if [ -z "${admin_password}" ]; then
      admin_password="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16 || true)"
      generated_password=1
    fi
  else
    admin_password="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16 || true)"
    generated_password=1
  fi

  echo "==> 检查 docker / docker compose"
  docker version >/dev/null
  docker compose version >/dev/null

  echo "==> 下载 Harbor ${HARBOR_VERSION} 在线安装包到 ${INSTALL_DIR}"
  mkdir -p "${INSTALL_DIR}"
  cd "${INSTALL_DIR}"
  if [ ! -f harbor.tgz ]; then
    curl -sL -o harbor.tgz \
      "https://github.com/goharbor/harbor/releases/download/${HARBOR_VERSION}/harbor-online-installer-${HARBOR_VERSION}.tgz"
  fi
  tar xzf harbor.tgz
  cd harbor

  echo "==> 生成 harbor.yml(hostname=${hostname_value}, port=${http_port})"
  cp harbor.yml.tmpl harbor.yml
  sed -i "s|^hostname:.*|hostname: ${hostname_value}|" harbor.yml
  sed -i "s|^  port: 80\$|  port: ${http_port}|" harbor.yml
  # 默认没有证书,先关闭 https 段;需要 https 时请自行准备证书并取消注释
  sed -i '/^https:/,/private_key:/s/^/#/' harbor.yml
  sed -i "s|^harbor_admin_password:.*|harbor_admin_password: ${admin_password}|" harbor.yml

  echo "==> 生成 Harbor 各组件配置(prepare)"
  ./prepare

  echo "==> 修复配置文件读取权限"
  # prepare 是用 --privileged 容器以 root 身份生成的这些文件,当前用户(即使在 docker 组里)
  # 直接 chmod 会因为不是文件属主而失败(Operation not permitted)。借用一个临时容器
  # (容器内是 root)来改权限,不需要 sudo。
  # 另外,不同组件容器内部运行身份也不一致(有的是 root,有的是 uid 10000 的非root账号),
  # 直接 chown 给宿主机某个用户会导致另一部分容器读不到配置,所以放开为所有人可读可写
  # (可写是因为下面 sed -i 要在同目录建临时文件再替换,需要目录写权限);
  # 生产暴露公网前应改用更精细的权限方案。
  docker run --rm -v "$(pwd)/common:/target" alpine chmod -R a+rwX /target

  echo "==> 屏蔽有兼容性问题的 syslog 日志驱动(改用 docker 默认日志)"
  # Harbor v2.15.2 镜像内置的 rsyslogd 版本与 prepare 生成的配置不兼容,
  # 会导致 harbor-log 及依赖它的容器反复重启。这里移除各服务的 logging 配置块,
  # 查日志改用 `docker logs <容器名>`。
  sed -i '/^    logging:$/,/^        tag:/d' docker-compose.yml

  echo "==> 同步 token 签发地址(EXT_ENDPOINT)"
  sed -i "s|^EXT_ENDPOINT=.*|EXT_ENDPOINT=http://${hostname_value}:${http_port}|" common/config/core/env

  echo "==> 启动 Harbor"
  docker compose up -d

  echo ""
  echo "=================================================="
  echo "Harbor 部署完成"
  echo "访问地址: http://${hostname_value}:${http_port}"
  echo "管理员账号: admin"
  echo "管理员密码: ${admin_password}"
  if [ "${generated_password}" = "1" ]; then
    echo "(这是自动生成的随机密码,登录后可在 admin 账号的个人设置里修改)"
  fi
  echo "以后忘记密码,用: $0 credentials"
  echo "API 文档: http://${hostname_value}:${http_port}/devcenter"
  echo "=================================================="
}

cmd_status() {
  if [ ! -f "${HARBOR_DIR}/docker-compose.yml" ]; then
    echo "没有检测到 Harbor 安装(找不到 ${HARBOR_DIR}/docker-compose.yml)"
    exit 1
  fi
  (cd "${HARBOR_DIR}" && docker compose ps)
}

cmd_credentials() {
  require_running
  local ext_endpoint password
  ext_endpoint="$(get_core_env EXT_ENDPOINT)"
  password="$(get_core_env HARBOR_ADMIN_PASSWORD)"
  echo "访问地址: ${ext_endpoint}"
  echo "管理员账号: admin"
  echo "管理员密码: ${password}"
}

cmd_uninstall() {
  echo "警告:此操作会永久删除 Harbor 的所有容器、配置,以及镜像仓库存储的全部数据(/data),不可恢复!"
  echo ""
  read -r -p "确认继续吗?输入大写 DELETE 继续,其他任意输入取消: " confirm1
  if [ "${confirm1}" != "DELETE" ]; then
    echo "已取消,没有做任何改动。"
    exit 0
  fi

  echo ""
  echo "最后确认:这会清空当前所有项目/客户在 Harbor 里已上传的镜像数据,无法恢复。"
  read -r -p "真的要卸载吗?输入 yes 继续: " confirm2
  if [ "${confirm2}" != "yes" ]; then
    echo "已取消,没有做任何改动。"
    exit 0
  fi

  echo "==> 停止并删除所有容器和网络"
  if [ -f "${HARBOR_DIR}/docker-compose.yml" ]; then
    (cd "${HARBOR_DIR}" && docker compose down)
  fi

  echo "==> 删除数据目录 /data"
  if [ -d /data ]; then
    docker run --rm -v /:/hostroot alpine rm -rf /hostroot/data
  fi

  echo "==> 删除安装目录 ${INSTALL_DIR}"
  rm -rf "${INSTALL_DIR}"

  echo "卸载完成。"
}

cmd_robot_create() {
  local project="${1:-}" name="${2:-}" duration="${3:-365}"
  if [ -z "${project}" ] || [ -z "${name}" ]; then
    echo "用法: $0 robot-create <project> <robot名> [有效天数,默认365]" >&2
    exit 1
  fi
  require_running
  local ext_endpoint password
  ext_endpoint="$(get_core_env EXT_ENDPOINT)"
  password="$(get_core_env HARBOR_ADMIN_PASSWORD)"
  curl -sf -u "admin:${password}" -X POST "${ext_endpoint}/api/v2.0/robots" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"${name}\",\"duration\":${duration},\"level\":\"project\",\"permissions\":[{\"kind\":\"project\",\"namespace\":\"${project}\",\"access\":[{\"resource\":\"repository\",\"action\":\"pull\"}]}]}"
  echo ""
}

cmd_robot_list() {
  local project="${1:-}"
  if [ -z "${project}" ]; then
    echo "用法: $0 robot-list <project>" >&2
    exit 1
  fi
  require_running
  local ext_endpoint password project_id
  ext_endpoint="$(get_core_env EXT_ENDPOINT)"
  password="$(get_core_env HARBOR_ADMIN_PASSWORD)"
  project_id="$(get_project_id "${ext_endpoint}" "${password}" "${project}")"
  if [ -z "${project_id}" ]; then
    echo "找不到项目: ${project}" >&2
    exit 1
  fi
  if command -v python3 >/dev/null 2>&1; then
    curl -sf -u "admin:${password}" -G "${ext_endpoint}/api/v2.0/robots" \
      --data-urlencode "q=Level=project,ProjectID=${project_id}" | python3 -m json.tool
  else
    curl -sf -u "admin:${password}" -G "${ext_endpoint}/api/v2.0/robots" \
      --data-urlencode "q=Level=project,ProjectID=${project_id}"
    echo ""
  fi
}

cmd_robot_revoke() {
  local robot_id="${1:-}"
  if [ -z "${robot_id}" ]; then
    echo "用法: $0 robot-revoke <robot_id>(先用 robot-list 查id)" >&2
    exit 1
  fi
  require_running
  local ext_endpoint password
  ext_endpoint="$(get_core_env EXT_ENDPOINT)"
  password="$(get_core_env HARBOR_ADMIN_PASSWORD)"
  curl -sf -u "admin:${password}" -X DELETE "${ext_endpoint}/api/v2.0/robots/${robot_id}"
  echo "已吊销 robot id ${robot_id}"
}

# 列出 Harbor 现有项目供选择,选完把结果放进全局变量 PICKED_PROJECT
# 用户选"返回"或取消时 PICKED_PROJECT 会是空字符串,调用方要检查这个再继续
pick_project() {
  PICKED_PROJECT=""
  if ! docker ps --format '{{.Names}}' | grep -qx harbor-core; then
    echo "Harbor 还没有运行,请先执行 1) 安装部署。"
    return
  fi
  local ext_endpoint password projects
  ext_endpoint="$(get_core_env EXT_ENDPOINT)"
  password="$(get_core_env HARBOR_ADMIN_PASSWORD)"
  projects="$(curl -sf -u "admin:${password}" "${ext_endpoint}/api/v2.0/projects?page_size=100" \
    | python3 -c "import sys,json
try:
    for p in json.load(sys.stdin):
        print(p['name'])
except Exception:
    pass" 2>/dev/null)"

  local -a names=()
  echo ""
  echo "---- 选择项目 ----"
  if [ -n "${projects}" ]; then
    local i=1
    while IFS= read -r name; do
      [ -z "${name}" ] && continue
      echo "${i}) ${name}"
      names+=("${name}")
      i=$((i+1))
    done <<< "${projects}"
  else
    echo "(当前没有任何项目)"
  fi
  echo "n) 输入新项目名(会自动创建)"
  echo "0) 返回主菜单"
  read -r -p "请选择: " sel

  if [ "${sel}" = "0" ] || [ -z "${sel}" ]; then
    return
  elif [ "${sel}" = "n" ] || [ "${sel}" = "N" ]; then
    read -r -p "新项目名(全小写): " newname
    if [ -n "${newname}" ]; then
      curl -sf -u "admin:${password}" -X POST "${ext_endpoint}/api/v2.0/projects" \
        -H "Content-Type: application/json" \
        -d "{\"project_name\":\"${newname}\",\"public\":false}" >/dev/null 2>&1 || true
      PICKED_PROJECT="${newname}"
    fi
  elif [[ "${sel}" =~ ^[0-9]+$ ]] && [ "${sel}" -ge 1 ] && [ "${sel}" -le "${#names[@]}" ]; then
    PICKED_PROJECT="${names[$((sel-1))]}"
  else
    echo "无效选择,已返回主菜单。"
  fi
}

show_menu() {
  # 交互菜单模式下,某一步操作失败(比如接口报错)不应该导致整个工具退出,
  # 应该是打印错误信息、回到菜单重新选。command 模式(带子命令直接跑)仍然保持 set -e 严格退出。
  set +e
  while true; do
    echo ""
    echo "================ Harbor 管理工具 ================"
    echo "1) 安装部署 Harbor"
    echo "2) 查看运行状态"
    echo "3) 查看管理员账号密码"
    echo "4) 创建客户拉取 key(robot account)"
    echo "5) 查看所有客户 key"
    echo "6) 吊销某个客户 key"
    echo "7) 卸载 Harbor(危险操作,不可恢复,会多次确认)"
    echo "0) 退出"
    echo "=================================================="
    read -r -p "请输入序号: " choice
    case "${choice}" in
      1) cmd_install ;;
      2) cmd_status ;;
      3) cmd_credentials ;;
      4)
        pick_project
        [ -z "${PICKED_PROJECT}" ] && continue
        read -r -p "客户/key 名称(比如 customer1,不返回请直接输入): " menu_name
        [ -z "${menu_name}" ] && { echo "已取消,返回主菜单。"; continue; }
        read -r -p "有效天数(直接回车默认365): " menu_duration
        menu_duration="${menu_duration:-365}"
        cmd_robot_create "${PICKED_PROJECT}" "${menu_name}" "${menu_duration}" \
          || echo "❌ 创建失败,请看上面的报错信息。"
        ;;
      5)
        pick_project
        [ -z "${PICKED_PROJECT}" ] && continue
        cmd_robot_list "${PICKED_PROJECT}" || echo "❌ 查询失败,请看上面的报错信息。"
        ;;
      6)
        pick_project
        [ -z "${PICKED_PROJECT}" ] && continue
        cmd_robot_list "${PICKED_PROJECT}"
        read -r -p "输入上面列表里要吊销的 robot id(直接回车返回主菜单): " menu_robot_id
        [ -z "${menu_robot_id}" ] && { echo "已取消,返回主菜单。"; continue; }
        cmd_robot_revoke "${menu_robot_id}" || echo "❌ 吊销失败,请看上面的报错信息。"
        ;;
      7) cmd_uninstall ;;
      0) echo "退出。"; exit 0 ;;
      *) echo "无效选项,请重新输入。" ;;
    esac
  done
}

if [ $# -eq 0 ]; then
  show_menu
fi

case "$1" in
  install) cmd_install ;;
  status) cmd_status ;;
  credentials) cmd_credentials ;;
  uninstall) cmd_uninstall ;;
  robot-create) shift; cmd_robot_create "$@" ;;
  robot-list) shift; cmd_robot_list "$@" ;;
  robot-revoke) shift; cmd_robot_revoke "$@" ;;
  *) usage; exit 1 ;;
esac
