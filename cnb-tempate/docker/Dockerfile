# FROM debian:bookworm-slim
FROM cnbcool/default-build-env

ENV DEBIAN_FRONTEND=noninteractive \
    TS_CHANNEL=stable \
    TS_TUN_MODE=userspace-networking \
    TS_STATE_DIR=/var/lib/tailscale \
    TS_SOCKET=/var/run/tailscale/tailscaled.sock

# 打印当前工作目录
RUN echo "构建上下文路径是: $(pwd)"

# RUN cat /etc/os-release
# COPY ./install-tailscale-debian.sh /usr/local/bin/install-tailscale-debian.sh
# RUN chmod +x /usr/local/bin/install-tailscale-debian.sh \
#     && /usr/local/bin/install-tailscale-debian.sh

# COPY ./entrypoint.sh /usr/local/bin/entrypoint.sh
# RUN chmod +x /usr/local/bin/entrypoint.sh

# VOLUME ["/var/lib/tailscale", "/var/run/tailscale"]

# ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
