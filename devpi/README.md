# devpi(私有 Python 包索引)

给内部私有库(比如 `fastapi-admin-core`,编译成 `.so` 之后)提供一个能正常 `pip install`/`uv add` 的私有源,读写都要账号密码,不是谁都能装、也不是谁都能看。

## 部署

```bash
./install.sh
```

会交互问一次密码(回车自动生成),部署完打印出地址、账号密码,以及发布方/消费方各自要怎么配置。

## 发布一个新版本(以 fastapi-admin-core 为例)

在库自己的仓库里,Cython 编译完(`.py` → `.so`)之后:

```bash
uv build   # 产出的 wheel 里是编译后的 .so,前提是 pyproject.toml 配了 hatch build hook(见下方)
devpi use http://vendor:<密码>@localhost:3141/vendor/prod
devpi upload dist/*.whl
```

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

`pyproject.toml`:

```toml
[[tool.uv.index]]
name = "internal"
url = "http://vendor:<密码>@localhost:3141/vendor/prod/+simple/"

[project]
dependencies = [
    "fastapi-admin-core>=0.1.5",
]
```

正常 `uv sync`/`uv add` 即可,依赖(`fastapi`/`sqlalchemy`等)会跟着 wheel 的 METADATA 自动解析安装,不用手动抄一份依赖清单。

CI 里用环境变量传密码,不要把密码硬编码进 `pyproject.toml`:

```toml
url = "http://vendor:${UV_INDEX_INTERNAL_PASSWORD}@localhost:3141/vendor/prod/+simple/"
```
(uv 支持 `UV_INDEX_<NAME>_USERNAME`/`UV_INDEX_<NAME>_PASSWORD` 环境变量,也支持直接在 url 里嵌变量,两种都行)
