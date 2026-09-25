# infra-deploy

从零搭一台新服务器需要的基础设施部署脚本——跟"怎么打包发布业务代码"([release-toolkit](https://github.com/wyunsi280-cell/release-toolkit))是两回事,这个仓库很少用到,只有换服务器/加新服务器的时候才需要。

脚本本身不含任何密码/token(密码都是部署时随机生成或交互输入),所以这个仓库是 public 的,方便一行命令远程部署。

## 包含什么

| 目录 | 是什么 | 一行安装 |
|---|---|---|
| [`harbor/`](./harbor) | Docker 镜像仓库(Harbor),给客户发独立拉取权限用 | `bash -c "$(curl -fsSL https://raw.githubusercontent.com/wyunsi280-cell/infra-deploy/main/harbor/harbor-ctl.sh)" bash install` |
| [`devpi/`](./devpi) | 私有 Python 包索引,内部库(比如 `fastapi-admin-core`)编译成 `.so` 后发布到这里,正常 `pip install` | `bash -c "$(curl -fsSL https://raw.githubusercontent.com/wyunsi280-cell/infra-deploy/main/devpi/bootstrap.sh)"` |

注意统一用的是 `bash -c "$(curl ...)"`,不是 `curl ... | bash`——两者看着差不多,交互体验完全不同:管道方式下 bash 是从 stdin 读脚本内容本身,stdin 被脚本源占用了,脚本里想 `read` 你的键盘输入时只能读到 EOF(表现为一路用默认值/自动生成密码,不会真的停下来问你);`bash -c "$(curl ...)"` 是把脚本内容当命令行参数传进去,stdin 没被占用,还连着你的终端,脚本里的 `read` 能正常弹出来问——这才是真正"一行搞定,过程中交互式填"的写法。

## devpi 部署

`devpi-ctl.sh` 自己不够——它要跟 `Dockerfile`/`entrypoint.sh`/`docker-compose.yml` 放一起才能 `docker compose` 起来,所以真正的一行安装是 `bootstrap.sh`(先把这几个文件拉齐,再跑 `devpi-ctl.sh install`):

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/wyunsi280-cell/infra-deploy/main/devpi/bootstrap.sh)"
```

跑起来会问你 vendor 密码和对外域名——域名这一步不确定的话直接回车留空,先在本机用 `localhost` 测,以后配好 Cloudflare 隧道再重新跑一遍这条命令、这次把域名填上(密码要填跟第一次一样的,不然 vendor 账号登录不上;数据在卷里,重新跑不会清空已有的账号/索引,只是让 devpi-server 知道自己新的对外地址)。

装到别的目录(默认是 `~/infra/devpi`,注意 `bash -c "..."` 后面第一个参数是占位的 `$0`,真正传给脚本的参数从第二个开始算):

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/wyunsi280-cell/infra-deploy/main/devpi/bootstrap.sh)" bash /custom/path
```

想完全不交互、给自动化/CI 用,才用管道 + 环境变量这个组合(会跳过所有交互提示):

```bash
export DEVPI_PASSWORD=your-password DEVPI_OUTSIDE_URL=https://devpi.example.com
curl -fsSL https://raw.githubusercontent.com/wyunsi280-cell/infra-deploy/main/devpi/bootstrap.sh | bash
```

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
