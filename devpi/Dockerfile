FROM python:3.13-slim
RUN pip install --no-cache-dir uv
# 用 uv 的依赖解析器装(踩过坑:普通 pip 在这几个包上会莫名回溯到
# httpx 2019年的老版本,老版本打包方式有问题装不上;uv 解析器不会这样)
RUN uv pip install --system --no-cache devpi-server devpi-web devpi-client
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
EXPOSE 3141
ENTRYPOINT ["/entrypoint.sh"]
