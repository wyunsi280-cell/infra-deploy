# devpi(私有 Python 包索引)

给内部私有库(比如 `fastapi-admin-core`,编译成 `.so` 之后)提供一个能正常 `pip install`/`uv add` 的私有源,读写都要账号密码,不是谁都能装、也不是谁都能看。

## 部署

一行远程用,不用先 clone 仓库(跟 `harbor-ctl.sh` 一样的风格):

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/wyunsi280-cell/infra-deploy/main/devpi/devpi-ctl.sh)"
```

不带参数直接运行是交互菜单(装/查状态/查密码/发协作者账号/收协作者账号),不用记参数。脚本第一次装的时候会自己把需要的 `Dockerfile`/`entrypoint.sh`/`docker-compose.yml` 拉到一个固定目录(`DEVPI_HOME`,默认 `~/infra/devpi`),不管你这份脚本是从哪运行的,以后每次用同一条命令都会操作同一个固定目录,账号状态不会丢。

也可以本地 clone 后跑 `./devpi-ctl.sh`,效果一样。

## 账号模型

- `vendor`:读+写(上传新版本用这个),密码在 `devpi-ctl.sh` 菜单选 1 部署时设置
- 协作者/下游项目 CI:只读,菜单选 3 单独发一个,选 5 单独收回——**这层权限在 Caddy 的 Basic Auth,不在 devpi 自己的用户系统里**,收回一个人不影响别人也不影响 vendor

## 发布一个新版本(以 fastapi-admin-core 为例)

在库自己的仓库里,Cython 编译完(`.py` → `.so`)之后:

```bash
uv build   # 产出的 wheel 里是编译后的 .so,前提是 pyproject.toml 配了 hatch build hook(见下方)
devpi use "https://vendor:<密码>@devpi.example.com/vendor/prod"
devpi upload dist/*.whl
```

**账号密码必须直接嵌在 `devpi use` 的 URL 里**,不能只在后面 `devpi login` 时才带——`devpi use` 自己会先探测一次 `+api` 端点,这个端点也在 Caddy 的 Basic Auth 后面,没带凭证的探测请求会被 401,导致客户端没能正确记住当前指向哪个 index,后面 `login`/`upload` 会用到过期缓存的地址,一样失败(实测踩过)。

`pyproject.toml` 需要一个 build hook,保证 wheel 打上正确的平台标签(`cp313-cp313-linux_x86_64`),不是默认的 `py3-none-any`(那个标签意味着"纯 Python、任何平台通用",对编译后的 `.so` 来说是错的,装到不兼容的环境会静默失败):

```toml
[tool.hatch.build.hooks.custom]
path = "hatch_build_hooks/tag_native.py"
```

```python
# hatch_build_hooks/tag_native.py
from hatchling.builders.hooks.plugin.interface import BuildHookInterface


class NativeTagHook(BuildHookInterface):
    def initialize(self, version, build_data):
        build_data["pure_python"] = False
        build_data["infer_tag"] = True
```

## 消费方怎么装

`pyproject.toml`(账号密码不写在这里,这个文件要提交到 git):

```toml
[[tool.uv.index]]
name = "internal"
url = "https://devpi.example.com/vendor/prod/+simple/"

[project]
dependencies = [
    "fastapi-admin-core>=0.1.5",
]
```

密码通过环境变量传,`uv` 支持 `UV_INDEX_<NAME大写>_USERNAME`/`UV_INDEX_<NAME大写>_PASSWORD`(index 名叫 `internal` 就是 `UV_INDEX_INTERNAL_USERNAME`/`UV_INDEX_INTERNAL_PASSWORD`):

```bash
UV_INDEX_INTERNAL_USERNAME=vendor UV_INDEX_INTERNAL_PASSWORD=<密码> uv sync
```

正常 `uv sync`/`uv add` 即可,依赖(`fastapi`/`sqlalchemy`等)会跟着 wheel 的 METADATA 自动解析安装,不用手动抄一份依赖清单。

**发新版本后记得 `uv lock --upgrade-package <包名>`**——`uv.lock` 锁的是具体版本号,devpi 上有新版本不会让已有项目自动跳过去,得显式升级锁文件(实测踩过:发了新版本,消费方一直没装上,以为哪里坏了,其实只是锁文件没更新)。

Docker 构建时(`build-and-publish.sh`)用 `DEVPI_INDEX_URL` 环境变量传完整地址(含账号密码),脚本会通过 BuildKit secret 注入,不会写进镜像层。
