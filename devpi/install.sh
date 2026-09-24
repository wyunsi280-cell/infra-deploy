#!/usr/bin/env bash
# 部署 devpi(私有 Python 包索引)+ Caddy(强制 Basic Auth,挡住所有未授权读写)。
# 用法: ./install.sh

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

echo "==================================================="
echo " devpi 私有包索引 部署"
echo "==================================================="

read -r -p "设置 vendor 账号密码(用于 Basic Auth 网关 + devpi 上传权限,回车自动生成): " DEVPI_PASSWORD
if [ -z "${DEVPI_PASSWORD}" ]; then
  DEVPI_PASSWORD="$(openssl rand -hex 12)"
  echo "自动生成的密码: ${DEVPI_PASSWORD}(请当场保存,后面查不回来明文)"
fi

echo "==> 生成 Caddy Basic Auth 密码哈希"
mkdir -p caddy
HASH="$(docker run --rm caddy:2-alpine caddy hash-password --plaintext "${DEVPI_PASSWORD}")"
cat > caddy/Caddyfile << EOF
:3141 {
	basic_auth {
		vendor ${HASH}
	}
	reverse_proxy devpi:3141
}
EOF

echo "==> 构建并启动容器"
docker compose up -d --build

echo "==> 等待 devpi-server 就绪"
for i in $(seq 1 30); do
  if docker compose exec -T devpi curl -sf http://localhost:3141/root/pypi/ >/dev/null 2>&1; then
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

echo ""
echo "==================================================="
echo "部署完成"
echo "地址: http://localhost:3141/vendor/prod/"
echo "账号: vendor"
echo "密码: ${DEVPI_PASSWORD}"
echo ""
echo "上传(在项目目录下,先 uv build 出 wheel):"
echo "  devpi use http://vendor:${DEVPI_PASSWORD}@localhost:3141/vendor/prod"
echo "  devpi upload dist/*.whl"
echo ""
echo "消费方 pyproject.toml 加索引:"
echo "  [[tool.uv.index]]"
echo "  name = \"internal\""
echo "  url = \"http://vendor:${DEVPI_PASSWORD}@localhost:3141/vendor/prod/+simple/\""
echo "==================================================="
