# infra-deploy

从零搭一台新服务器需要的基础设施部署脚本——跟"怎么打包发布业务代码"([release-toolkit](https://github.com/wyunsi280-cell/release-toolkit))是两回事,这个仓库很少用到,只有换服务器/加新服务器的时候才需要。

脚本本身不含任何密码/token(密码都是部署时随机生成或交互输入),所以这个仓库是 public 的,方便一行命令远程部署。

## 包含什么

| 目录 | 是什么 | 一行安装 |
|---|---|---|
| [`harbor/`](./harbor) | Docker 镜像仓库(Harbor),给客户发独立拉取权限用 | `curl -fsSL https://raw.githubusercontent.com/wyunsi280-cell/infra-deploy/main/harbor/harbor-ctl.sh \| bash -s -- install` |
| [`devpi/`](./devpi) | 私有 Python 包索引,内部库(比如 `fastapi-admin-core`)编译成 `.so` 后发布到这里,正常 `pip install` | 见下方 |

## devpi 部署

```bash
curl -fsSL https://raw.githubusercontent.com/wyunsi280-cell/infra-deploy/main/devpi/devpi-ctl.sh -o /tmp/devpi-devpi-ctl.sh
mkdir -p ~/infra/devpi && cd ~/infra/devpi
curl -fsSL https://raw.githubusercontent.com/wyunsi280-cell/infra-deploy/main/devpi/Dockerfile -o Dockerfile
curl -fsSL https://raw.githubusercontent.com/wyunsi280-cell/infra-deploy/main/devpi/entrypoint.sh -o entrypoint.sh
curl -fsSL https://raw.githubusercontent.com/wyunsi280-cell/infra-deploy/main/devpi/docker-compose.yml -o docker-compose.yml
bash /tmp/devpi-devpi-ctl.sh
```

(需要 build context 里的文件,所以不是单纯一行 `curl | bash`——上面这几行把需要的文件都拉齐再跑安装脚本。以后如果嫌麻烦可以把这几行包成一个 `bootstrap.sh` 只用一行调。)

装完是:
- `devpi-server`(私有包索引本体)+ `devpi-web`(网页界面),只监听容器内部,外部连不到
- `Caddy` 挡在前面做 Basic Auth,**读写都要密码**,对外的 `3141` 端口是唯一入口
- `devpi-server` 的 `--request-timeout` 调到 30 秒(默认 5 秒对访问 PyPI 偶尔的慢连接太短,实测踩过坑:某个依赖包第一次被请求时会因为超时返回空版本列表,被 pip/uv 误判成"不存在这个包")
- `devpi-server` 传了 `--secretfile`(密钥存进持久卷)——不传的话每次容器重启都生成新密钥,而这个密钥还参与密码校验,重启一次所有账号密码就全部失效,报错还完全看不出原因
- 已经配了公网域名(Cloudflare),用 `--outside-url` 告诉 devpi-server 它对外的真实地址,不然它会拿内部连接协议(明文http)拼登录/上传链接,外部走 https 访问时对不上

`vendor` 账号读写都有权限(上传新版本用这个)。协作者/下游项目 CI 只需要读权限,用 `devpi-ctl.sh` 菜单选 3/5 单独发/收账号,互不影响——这层权限在 Caddy,不在 devpi 自己的用户系统里。

用法(发布/消费私有库)见 [devpi/README.md](./devpi/README.md) 或直接看 [`devpi-ctl.sh`](./devpi/devpi-ctl.sh) 跑完之后打印的说明。

## 已知限制

- Harbor 和 devpi 目前是各自独立部署,没有做统一的备份/监控,量大了之后需要补
