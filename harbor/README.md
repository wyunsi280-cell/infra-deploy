# Harbor 部署教程

> 配套脚本:[`harbor-ctl.sh`](./harbor-ctl.sh)(部署、查密码、建/吊销客户key、卸载,一个脚本搞定)
> 本文档基于在 WSL2 Ubuntu 上的实际部署过程整理,踩坑记录见 [release-toolkit 仓库的架构设计.md](https://github.com/wyunsi280-cell/release-toolkit/blob/main/架构设计.md) 第3.5.1节
>
> 这个脚本管的是"部署基础设施本身"(Harbor 这个服务),跟"怎么打包发布业务代码"是两码事——后者在 [release-toolkit](https://github.com/wyunsi280-cell/release-toolkit) 仓库。同级目录的 [`../devpi/`](../devpi/) 是私有 Python 包索引,跟 Harbor 配合使用但完全独立部署。
>
> 一行远程安装:
> ```bash
> curl -fsSL https://raw.githubusercontent.com/wyunsi280-cell/infra-deploy/main/harbor/harbor-ctl.sh -o harbor-ctl.sh && chmod +x harbor-ctl.sh && ./harbor-ctl.sh
> ```

## 1. 前提条件

- 服务器已安装 **Docker** 和 **Docker Compose v2**(执行 `docker compose version` 能看到版本号)
- 当前用户在 `docker` 用户组里,不需要 `sudo` 就能跑 docker 命令(用 `docker ps` 测试一下)
- 准备好一个没被占用的端口(默认建议 8090,如果服务器上跑了宝塔/nginx/apache 之类的东西,80/443 大概率已经被占用)
- 能访问 GitHub(脚本会从 GitHub Releases 下载 Harbor 安装包)

> 宝塔用户注意:宝塔应用商店里有官方 Harbor 插件,但它依赖自动识别"服务器IP"这一步,在 WSL 这类虚拟化/NAT网络环境下识别不出来,装到一半会卡死在 `${SERVER_IP}` 占位符没替换的状态,卸载重装也没用。遇到这种情况就不要再试宝塔插件了,直接用这个脚本。

## 2. 使用方式

不用记任何命令或参数,直接运行:

```bash
chmod +x harbor-ctl.sh
./harbor-ctl.sh
```

会看到:

```
================ Harbor 管理工具 ================
1) 安装部署 Harbor
2) 查看运行状态
3) 查看管理员账号密码
4) 创建客户拉取 key(robot account)
5) 查看所有客户 key
6) 吊销某个客户 key
7) 卸载 Harbor(危险操作,不可恢复,会多次确认)
0) 退出
==================================================
请输入序号:
```

选哪个功能,脚本会接着问需要的信息,全程只需要照着提示打字或选序号:

- 涉及"选项目"的地方(建key/查key/吊销key),会**自动列出 Harbor 里现有的项目给你选序号**;选"输入新项目名"还会**自动帮你把这个新项目建好**,不需要单独去建
- 每一步都有"0) 返回主菜单"可以随时退出,不用 Ctrl+C 硬中断
- 某一步操作失败(比如接口报错)只会提示错误、回到菜单,不会导致整个工具退出

下面按菜单序号逐条说明每个选项实际在做什么。

### 2.1 安装部署 Harbor(菜单选 1)

会依次问你:
1. **对外访问的域名或IP**(直接回车用 `localhost`,只适合本机/内网测试;真要给外部客户用,必须填真实域名或公网IP,这个值会写进 token 签发地址,客户端 `docker login`/`pull` 都靠它)
2. **对外访问端口**(直接回车用 `8090`)
3. **管理员密码**(直接回车会自动生成一个16位随机密码并在结尾打印出来,记得当场保存;也可以自己输入)

安装过程内部自动处理了这几件事(具体原因见架构文档踩坑记录):
- `prepare` 生成的配置文件是 root 身份写的,当前用户读不了、也没法在同目录建临时文件 —— 借用临时容器修正为所有人可读写
- 屏蔽有兼容性问题的 syslog 日志驱动,改用 docker 默认日志(查日志用 `docker logs <容器名>`)
- 同步 token 签发地址端口

### 2.2 查看运行状态(菜单选 2)

列出所有 Harbor 容器的运行/健康状态,一眼看出是不是哪个组件挂了。

### 2.3 查看管理员账号密码(菜单选 3)

现查现取,直接从运行中的 `harbor-core` 容器环境变量里读,**不会额外落一份明文文件到磁盘**(考虑过存文件方便查,但多一份明文密码副本等于多一个泄露面,权衡下来不划算,详见下方"关于密码找回")。

### 2.4 创建客户拉取 key(菜单选 4)

给外部客户发放镜像拉取权限,靠的是 Harbor 的 **robot account** 机制:同一个镜像,可以给不同客户建不同的账号密钥,每个都能单独设有效期、单独吊销,不需要为每个客户重新构建镜像。

选 4 之后会:
1. 列出现有项目给你选(或者选"输入新项目名"自动建一个新的——一个项目相当于一条产品线/一类客户的镜像空间)
2. 问客户/key 名称(比如 `customer1`,只能小写字母、数字、连字符)
3. 问有效天数(直接回车默认365天)

生成的 `secret` 就是要发给客户的密钥,账号名类似 `robot$项目名+customer1`。客户那边自己执行:

```bash
docker login 你的地址:端口 -u 'robot$项目名+customer1' -p '返回的secret'
docker pull 你的地址:端口/项目名/镜像名:tag
```

**注意:菜单这里建的 robot 账号权限固定是 pull-only**,适合发给客户/下游项目的 CI(只需要拉取)。如果是给**内部发布流水线**用(比如 `fastapi-admin-core` 自己的 CI 要把编译产物 push 到 `internal-core` 项目),需要 push+pull 权限,菜单没有这个选项,直接调 API 建:

```bash
curl -sf -u "admin:密码" -X POST "https://你的域名/api/v2.0/robots" \
  -H "Content-Type: application/json" \
  -d '{"name":"账号名","duration":3650,"level":"project","permissions":[{"kind":"project","namespace":"项目名","access":[{"resource":"repository","action":"pull"},{"resource":"repository","action":"push"}]}]}'
```

这种 push+pull 的账号只应该发给"会往 Harbor 推东西"的自动化流程(比如某个私有库自己的发布 CI),不要发给客户或者只需要拉取的下游项目——按最小权限原则,拉取用 pull-only,发布用 push+pull,两种账号分开建、分开管理。

### 2.5 查看所有客户 key(菜单选 5)

选个项目,列出这个项目下发出去的所有 key(含 id、名称、有效期等)。

### 2.6 吊销某个客户 key(菜单选 6)

选个项目,先列出这个项目下的所有 key,再照着列表里的 id 输入要吊销哪个。吊销立即生效,只影响这一个客户,不影响同项目下的其他客户。

### 2.7 卸载(菜单选 7)

**危险操作,不可恢复。** 会经过两次确认:第一次要求输入大写 `DELETE`,第二次要求输入 `yes` 并会明确提示"这会清空所有镜像数据、不可恢复"。任何一次输入不对都会直接取消、不做任何改动。确认后会删除所有容器、网络、镜像数据目录(`/data`)和安装目录。

### 关于密码找回

**Harbor 的管理员密码一旦初始化就没法"看回来"**——数据库里存的是密码的单向哈希(bcrypt),不是明文,无法反解。而且密码只在**数据库第一次初始化时**生效,后面重装或重启,并不会重置已有密码,这是个常见的误区。真忘了,只能通过直接改数据库里的密码哈希来重置(不同版本操作细节可能不同,建议查 Harbor 官方文档/GitHub issue 里对应版本的做法),比较麻烦——所以更实际的做法是平时就用菜单选 3 随查随看。

**如果是用宝塔管理 Docker,也可以不用这个工具查**:`HARBOR_ADMIN_PASSWORD` 这个变量本来就在 `harbor-core` 容器的环境变量里(跟官方 Mongo/Postgres 镜像用 `MONGO_INITDB_ROOT_PASSWORD` 存密码是同一套机制)。直接在宝塔面板 → Docker → 容器列表 → 找到 `harbor-core` 容器 → 容器详情 → ENV,就能看到密码(变量比较多,建议用浏览器 `Ctrl+F` 精确搜 `HARBOR_ADMIN_PASSWORD`,避免跟 `POSTGRESQL_PASSWORD`、`REGISTRY_CREDENTIAL_PASSWORD` 这些无关变量搞混)。注意:这个 ENV 列表的显示顺序是 Docker Compose 内部机制决定的、没法人为调整,账号密码不会排在最前面。

## 3. 部署后验证

**浏览器验证:** 打开 `http://你的地址:端口`,用 `admin` / 菜单选 3 查到的密码登录。

**命令行验证(可选):**

```bash
curl http://你的地址:端口/api/v2.0/systeminfo
```

返回一段 JSON(包含 `auth_mode` 字段)说明服务正常。

## 4. 给自动化脚本用的命令行模式(进阶,日常不需要)

`harbor-ctl.sh` 内部其实也支持带参数的命令行子命令(`install`/`status`/`credentials`/`uninstall`/`robot-create`/`robot-list`/`robot-revoke`),日常使用完全用不到、也不需要记——这套是留给以后写自动化脚本(比如 [`build-and-publish.sh`](./产品打包分发教程.md)发布完新版本后自动调用)用的。具体参数格式可以直接看脚本源码里对应的 `cmd_*` 函数,这里不展开。

## 5. 用域名 + Cloudflare 对外暴露(已验证)

现在用的是 **Cloudflare 把域名(`harbor.touks.eu.org`)映射到本机 Harbor** 的方案,不需要自己搞 TLS 证书——HTTPS 在 Cloudflare 那一侧终止,内部 Harbor 本身还是跑明文 HTTP,Cloudflare 到 Harbor 这一段走隧道/代理。已经实测过 `docker login`/`push`/`pull` 通过这个域名全部正常。

**换域名(或从 localhost 切到域名)必须同步改两个地方**,不然客户端登录会失败(token 签发地址不对):
- `harbor.yml` 里的 `hostname`
- `common/config/core/env` 里的 `EXT_ENDPOINT`

改完要重建 `harbor-core` 容器(`docker compose up -d --force-recreate core`)才会生效。这是我们踩过两次的坑(第一次是端口从80换到8090,第二次是这次从 localhost 换到域名),规律都一样。

## 6. 已知限制 / TODO

- 配置文件权限统一放开为 `a+rwX` 是为了绕开"不同组件容器内部运行身份不一致"这个问题图省事的做法,严格意义上不是最小权限实践,内网/测试环境可以接受,正式生产环境建议评估更精细的权限方案
- `harbor-log` 的 rsyslog 兼容性问题目前是绕过(禁用 syslog 日志驱动),没有从根源修复,如果后续升级 Harbor 版本,建议先确认官方是否已修复该问题
- 宝塔官方 Harbor 插件在 WSL 环境下无法使用(IP 自动识别失效),已确认放弃,统一用 `harbor-ctl.sh`
- 客户隔离是"项目级"的,同一项目内的多个 robot key 之间没有仓库级别的进一步隔离,规划项目结构时要按客户/产品线拆分项目(已实测验证,见 [产品打包分发教程.md](./产品打包分发教程.md))
