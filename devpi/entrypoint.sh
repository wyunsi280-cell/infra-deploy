#!/bin/bash
set -e

if [ ! -f /data/.nodeinfo ]; then
  devpi-init --serverdir /data
fi

# 不传 --secretfile 的话,devpi-server 每次启动都会生成一个新的随机密钥——
# 这个密钥不只是session token签发用,还参与密码校验,一重启所有账号的密码
# 就全部认证失败(不是"要重新登录"这么简单,是密码本身验证不过)。
# 密钥存进持久卷,保证跨重启一致。
if [ ! -f /data/.secret ]; then
  devpi-gen-secret --secretfile /data/.secret
fi

OUTSIDE_URL_ARG=""
if [ -n "${DEVPI_OUTSIDE_URL:-}" ]; then
  # 告诉 devpi 它对外的真实地址(比如 https://devpi.touks.eu.org)——不设的话,
  # devpi 会用它看到的内部连接协议(Caddy 转发过来的是明文 http)去拼登录/上传
  # 用的自引用链接,导致外部走 https 域名访问时,登录请求被拼成 http 链接,
  # 中途被 Cloudflare/Caddy 重定向到 https 时把 POST 的凭证弄丢,报 401。
  OUTSIDE_URL_ARG="--outside-url ${DEVPI_OUTSIDE_URL}"
fi

exec devpi-server --serverdir /data --host 0.0.0.0 --port 3141 --request-timeout 30 \
  --secretfile /data/.secret ${OUTSIDE_URL_ARG}
