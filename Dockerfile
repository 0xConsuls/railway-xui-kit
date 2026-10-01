# =============================================================================
# Dockerfile — 3x-ui behind a single-port nginx router.
# Volume mount path: /etc/x-ui
# =============================================================================
FROM alpine:3.22

# Pin the panel version. To upgrade: change the number, commit, Railway rebuilds.
# Your data lives on the volume (/etc/x-ui) and is kept.
ARG XUI_VERSION=3.8.5
# Filled in automatically by BuildKit (amd64 / arm64).
ARG TARGETARCH=amd64

RUN apk add --no-cache \
        bash curl ca-certificates tzdata sqlite nginx fail2ban iptables \
    && mkdir -p /etc/nginx/snippets /run/nginx /etc/x-ui /var/log/x-ui

RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) arch=amd64 ;; \
      arm64) arch=arm64 ;; \
      *) echo "unsupported arch: ${TARGETARCH}"; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/x-ui.tar.gz \
      "https://github.com/mhsanaei/3x-ui/releases/download/v${XUI_VERSION}/x-ui-linux-${arch}.tar.gz"; \
    tar -xzf /tmp/x-ui.tar.gz -C /usr/local/; \
    rm -f /tmp/x-ui.tar.gz; \
    chmod +x /usr/local/x-ui/x-ui; \
    chmod +x /usr/local/x-ui/bin/* 2>/dev/null || true

# fail2ban: the stock ssh jails fail inside a container without sshd.
RUN rm -f /etc/fail2ban/jail.d/alpine-ssh.conf \
    && cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local \
    && sed -i 's/^\[sshd\]$/&\nenabled = false/; s/^\[ssh\]$/&\nenabled = false/' /etc/fail2ban/jail.local

COPY core/      /opt/kit/core/
COPY adapters/  /opt/kit/adapters/
COPY core/proxy-common.conf /etc/nginx/snippets/proxy-common.conf
RUN chmod +x /opt/kit/core/*.sh /opt/kit/adapters/*.sh

ENV KIT_DIR=/opt/kit \
    PANEL_ADAPTER=3x-ui \
    TZ=Asia/Tehran \
    XUI_IN_DOCKER=true \
    XUI_MAIN_FOLDER=/usr/local/x-ui \
    XUI_BIN_FOLDER=/usr/local/x-ui/bin \
    XUI_DB_FOLDER=/etc/x-ui \
    XUI_LOG_FOLDER=/var/log/x-ui \
    XUI_ENABLE_FAIL2BAN=true \
    XUI_SKIP_HSTS=true \
    XUI_AUTO_SOCKOPT=true

# No VOLUME instruction on purpose: Railway rejects it. Attach a volume at
# /etc/x-ui from the dashboard instead.
# No EXPOSE either: Railway routes by the domain's "Target Port" (HTTP_PORT,
# default 3000) and by the TCP proxy's application port.

ENTRYPOINT ["/opt/kit/core/entrypoint.sh"]
