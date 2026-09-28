#!/usr/bin/env bash
# 管理 license-system 已签发的 key——直接运行,跟着菜单提示选择、按要求输入
# 就行。这个脚本只是个薄壳(纯 HTTP 请求),不含任何密码/服务端源码,所以能
# 放在这个公开仓库里,跟 harbor-ctl.sh/devpi-ctl.sh 一样一行远程调用:
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/wyunsi280-cell/infra-deploy/main/license/license-ctl.sh)"
#
# license-system 服务本身的部署/重装不在这个脚本里——它的镜像是从私有仓库
# 现场编译的(不是像 Harbor/devpi 那样拉官方现成镜像),这一步离不开先有源码
# 在本地,没法做成公开一行部署,得去 license-system 私有仓库里
# `docker compose up -d --build`。这个脚本管的是"服务已经跑起来之后,日常
# 签发/查询/吊销/恢复 key"这些操作。
#
# 服务地址不写死默认值(这样这个公开脚本里不会出现任何真实域名),必须显式
# 传:
#   LICENSE_SERVER_URL=https://license.example.com ./license-ctl.sh
# 不设的话,tty 是交互终端时会提示手动输入;非交互(比如 curl|bash 管道里
# 没有终端)时直接报错退出,不会用任何猜测的默认值。
#
# 签发的 key 是 Ed25519 签过名的紧凑 token(不是 JWT,格式更短,约110字符),
# 吊销/恢复认的是 jti(菜单5查看列表能看到每个 key 对应的 jti 和备注)。
# 全部走 POST,跟服务端 API 一致。
#
# 也支持命令行子命令模式(给自动化脚本用,日常不需要记):
#   LICENSE_SERVER_URL=https://xxx ./license-ctl.sh issue [备注] | check [key] | revoke [jti] | restore [jti] | list

set -euo pipefail

get_server_url() {
  local url="${LICENSE_SERVER_URL:-}"
  if [ -z "${url}" ] && [ -t 0 ]; then
    read -r -p "license-system 的地址(比如 https://license.example.com): " url
  fi
  if [ -z "${url}" ]; then
    echo "错误: 没有设置 LICENSE_SERVER_URL,也没有从终端交互输入拿到,没法继续。" >&2
    echo "用法: LICENSE_SERVER_URL=https://xxx $0 [issue|check|revoke|restore|list]" >&2
    exit 1
  fi
  echo "${url}"
}

BASE_URL="$(get_server_url)"

get_admin_token() {
  if [ -n "${ADMIN_TOKEN:-}" ]; then
    echo "${ADMIN_TOKEN}"
    return
  fi
  read -r -s -p "ADMIN_TOKEN(部署时生成、存在 .env 里,输入不会显示): " token >&2
  echo "" >&2
  echo "${token}"
}

cmd_issue() {
  local note="${1:-}" token
  if [ -z "${note}" ]; then
    read -r -p "备注(比如客户名/用途,方便以后在列表里认出来,可以留空): " note
  fi
  token="$(get_admin_token)"
  curl -sf -X POST -H "Authorization: Bearer ${token}" -H "Content-Type: application/json" \
    -d "{\"note\": $([ -n "${note}" ] && echo "\"${note}\"" || echo null)}" \
    "${BASE_URL}/admin/issue"
  echo ""
}

cmd_check() {
  local key="${1:-}"
  if [ -z "${key}" ]; then
    read -r -p "要查询的 key(完整的那一长串): " key
  fi
  [ -z "${key}" ] && { echo "取消。"; return; }
  curl -sf -X POST -H "Content-Type: application/json" -d "{\"key\": \"${key}\"}" "${BASE_URL}/check"; echo
}

cmd_revoke() {
  local jti="${1:-}" token
  if [ -z "${jti}" ]; then
    read -r -p "要吊销的 jti(先用菜单4查列表): " jti
  fi
  [ -z "${jti}" ] && { echo "取消。"; return; }
  token="$(get_admin_token)"
  curl -sf -X POST -H "Authorization: Bearer ${token}" -H "Content-Type: application/json" \
    -d "{\"jti\": \"${jti}\"}" "${BASE_URL}/admin/revoke"; echo
}

cmd_restore() {
  local jti="${1:-}" token
  if [ -z "${jti}" ]; then
    read -r -p "要恢复的 jti(先用菜单4查列表): " jti
  fi
  [ -z "${jti}" ] && { echo "取消。"; return; }
  token="$(get_admin_token)"
  curl -sf -X POST -H "Authorization: Bearer ${token}" -H "Content-Type: application/json" \
    -d "{\"jti\": \"${jti}\"}" "${BASE_URL}/admin/restore"; echo
}

cmd_list() {
  local token
  token="$(get_admin_token)"
  curl -sf -X POST -H "Authorization: Bearer ${token}" "${BASE_URL}/admin/list"; echo
}

show_menu() {
  set +e
  while true; do
    echo ""
    echo "================ license 管理工具 ================"
    echo " 服务地址: ${BASE_URL}"
    echo "1) 签发一个新 key"
    echo "2) 查询某个 key 是否有效"
    echo "3) 吊销一个 key(按 jti)"
    echo "4) 恢复一个 key(按 jti)"
    echo "5) 查看所有已签发的 key"
    echo "0) 退出"
    echo "==================================================="
    read -r -p "请输入序号: " choice
    case "${choice}" in
      1) cmd_issue || echo "❌ 签发失败,请看上面的报错信息。" ;;
      2) cmd_check || echo "❌ 查询失败,请看上面的报错信息。" ;;
      3) cmd_revoke || echo "❌ 吊销失败,请看上面的报错信息。" ;;
      4) cmd_restore || echo "❌ 恢复失败,请看上面的报错信息。" ;;
      5) cmd_list || echo "❌ 查询失败,请看上面的报错信息。" ;;
      0) echo "退出。"; exit 0 ;;
      *) echo "无效选项,请重新输入。" ;;
    esac
  done
}

if [ $# -eq 0 ]; then
  show_menu
else
  case "$1" in
    issue) shift; cmd_issue "$@" ;;
    check) shift; cmd_check "$@" ;;
    revoke) shift; cmd_revoke "$@" ;;
    restore) shift; cmd_restore "$@" ;;
    list) cmd_list ;;
    *) echo "用法: $0 [issue [备注]|check [key]|revoke [jti]|restore [jti]|list]" >&2; exit 1 ;;
  esac
fi
