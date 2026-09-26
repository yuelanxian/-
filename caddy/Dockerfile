# HomeVault：带 DNS 服务商插件的 Caddy（仅 HV_TLS_MODE=acme-dns 时由 compose.acme.yaml 构建）
# 镜像地址可通过构建参数替换为国内镜像源；GOPROXY 由 HV_GOPROXY 传入。
ARG CADDY_BUILDER_IMAGE=docker.io/library/caddy:2.11.4-builder
ARG CADDY_BASE_IMAGE=docker.io/library/caddy:2.11.4-alpine

FROM ${CADDY_BUILDER_IMAGE} AS builder
ARG GOPROXY=https://proxy.golang.org,direct
# Optional PEM text of an extra root CA, only for networks with a TLS-intercepting proxy.
# Used during the build only; it never reaches the final image.
ARG EXTRA_CA_PEM=""
ENV GOPROXY=${GOPROXY}
RUN set -eu; \
	if [ -n "${EXTRA_CA_PEM}" ]; then \
		cat /etc/ssl/certs/ca-certificates.crt > /tmp/hv-ca.pem; \
		printf '%s\n' "${EXTRA_CA_PEM}" >> /tmp/hv-ca.pem; \
		export SSL_CERT_FILE=/tmp/hv-ca.pem; \
	fi; \
	xcaddy build v2.11.4 \
		--with github.com/caddy-dns/alidns@v1.0.29 \
		--with github.com/caddy-dns/tencentcloud@v0.4.3 \
		--with github.com/caddy-dns/cloudflare@v0.2.4; \
	rm -f /tmp/hv-ca.pem; \
	/usr/bin/caddy list-modules | grep -E '^dns\.providers\.(alidns|tencentcloud|cloudflare)$'

FROM ${CADDY_BASE_IMAGE}
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
LABEL org.opencontainers.image.title="homevault/caddy-dns" \
	org.opencontainers.image.description="Caddy 2.11.4 + caddy-dns alidns/tencentcloud/cloudflare"
