# admin-platform 客户部署教程

> 配套脚本:[`admin-platform-deploy.sh`](./admin-platform-deploy.sh)(部署/更新、查状态、查日志、改配置、卸载,一个脚本搞定)
>
> 这个脚本管的是"把已经发布到 Harbor 的 `admin-platform` 镜像跑起来给客户用",不是"怎么开发/打包 `admin-platform`"——后者见
> [release-toolkit 仓库的产品发布操作.md](https://github.com/wyunsi280-cell/release-toolkit/blob/main/产品发布操作.md)。
> 跟 [`../license/license-deploy.sh`](../license/license-deploy.sh) 的区别:
> `license-system` 只有 vendor 自己部署一份,这个脚本是**发给客户在客户自己
> 服务器上跑**的。
>
> 一行远程调用:
> ```bash
> bash -c "$(curl -fsSL https://raw.githubusercontent.com/wyunsi280-cell/infra-deploy/main/admin-platform/admin-platform-deploy.sh)"
> ```

## 给一个新客户部署前,要先准备好三样东西

1. **Harbor 拉取权限**——`harbor-ctl.sh` 菜单 4 给这个客户建一个 robot account(比如 `robot$admin-platform+客户名`),**不要把 vendor 自己的 admin 密码给客户**
2. **license key**——`license-ctl.sh` 菜单 1(或者命令行 `./license-ctl.sh issue "客户名"`)签发一个专属这个客户的 key,填进 `CORE_INSTANCE_KEY`
3. **Postgres 连接串**——客户自己有 Postgres 的话直接要连接串;没有的话目前**还没有标准化的流程**(这是个已知缺口,还没决定是"在客户服务器上顺手起一个 Postgres 容器"还是别的方案,后续定下来会补进这份文档)

## 部署

跑上面那行命令,选 `1`。依次会问:

- Harbor 地址(直接回车用默认)
- Harbor 用户名(**这里要填第1步建的 robot account**,格式类似 `robot$admin-platform+客户名`)
- Harbor 密码/robot secret
- 镜像 tag(比如 `v0.1.2`,发布时 `build-and-publish.sh` 打的那个——**每次部署都要显式指定,不用 `:latest`**,不同客户可以停在不同版本,不想升级就不用管)

**拉取镜像前会自动验证 Cosign 签名**,验不过直接拒绝部署,没有跳过选项——细节见
[cosign操作手册.md](https://github.com/wyunsi280-cell/release-toolkit/blob/main/cosign操作手册.md)。

第一次部署(没有 `.env`)还会问:

- `CORE_INSTANCE_KEY`(第2步签发的 license key)
- `DATABASES`(第3步准备的连接串,JSON 格式:`{"default": "postgresql+asyncpg://user:pass@host/db"}`)
- `REDIS`(没有直接回车跳过)

这些应用配置存进 `~/infra/admin-platform/.env`,以后 `deploy` 更新版本不用重新输,除非要改用菜单 `5`。

## 日常操作

```
1) 部署/更新(拉指定 tag 镜像并重启,第一次跑会问 license key/数据库配置)
2) 查看运行状态
3) 查看日志(Ctrl+C 退出)
4) 卸载(危险操作,不可恢复,会多次确认)
5) 更新应用配置(license key 换了 / 数据库连接串改了 用这个,不用重新拉镜像)
```

给客户发新版本:`build-and-publish.sh` 那边打新 tag 发布完,客户机器上重新跑一遍这份脚本选 `1`,改填新 tag 就行。

## 收回一个客户

两件事都要做,只做一个不够(见 [Harbor操作手册.md](https://github.com/wyunsi280-cell/release-toolkit/blob/main/Harbor操作手册.md)/[license操作手册.md](https://github.com/wyunsi280-cell/release-toolkit/blob/main/license操作手册.md)):

1. `harbor-ctl.sh` 菜单 6 吊销这个客户的 robot account(拉不到新镜像了,已经拉过的镜像还能继续跑)
2. `license-ctl.sh` 菜单 3 吊销这个客户的 license key(客户那边实例最多 5 分钟内自己停掉)

## 真实踩过的坑

1. **`status`/`logs`/`uninstall` 之前会直接报错**(`required variable IMAGE_TAG is missing a value`)——`docker compose` 解析 compose 文件里的 `${IMAGE_TAG}` 靠 `--env-file`,这个值只在 `deploy` 那次手动传了,重新跑脚本执行别的子命令时读不到。已修:部署时把 `HARBOR_REGISTRY`/`IMAGE_TAG` 存进独立的 `.env.deploy`(不跟业务配置 `.env` 混在一起),所有子命令统一走带 `--env-file` 的 helper。
2. **`update-config` 之前压根没法非交互调用**——没接进子命令分发,而且几个 `read` 没有 tty 判断,非交互跑会卡死等输入。已修:加了 `NEW_CORE_INSTANCE_KEY`/`NEW_DATABASES`/`NEW_REDIS` 环境变量作为非交互输入源。
