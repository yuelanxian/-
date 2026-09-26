# HomeVault 管理面板镜像（在本机构建，不从任何镜像仓库拉取 homevault/panel）。
# 构建：docker build -t homevault/panel:0.1.0 --build-arg REGISTRY=docker.io/library panel/
# 国内镜像：--build-arg REGISTRY=docker.m.daocloud.io/library
# 注意：不使用 "# syntax=" 指令，避免 BuildKit 额外拉取 docker/dockerfile 前端镜像。
ARG REGISTRY=docker.io/library
ARG GO_IMAGE=golang:1.26-alpine

FROM ${REGISTRY}/${GO_IMAGE} AS build
ARG VERSION=0.1.0
# 只用标准库：不需要下载任何依赖，也不自动下载其他版本的 Go 工具链
ENV CGO_ENABLED=0 GOTOOLCHAIN=local GOPROXY=off
WORKDIR /src
COPY go.mod ./
COPY cmd ./cmd
COPY internal ./internal
COPY web ./web
RUN go build -trimpath -ldflags "-s -w -X main.version=${VERSION}" -o /out/panel ./cmd/panel \
 && /out/panel version

FROM scratch
ARG VERSION=0.1.0
LABEL org.opencontainers.image.title="homevault-panel" \
      org.opencontainers.image.description="HomeVault 管理面板" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.licenses="MIT"
COPY --from=build /out/panel /panel
USER 65532:65532
EXPOSE 8080
ENV PANEL_LISTEN=:8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 CMD ["/panel", "healthcheck"]
ENTRYPOINT ["/panel"]
CMD ["serve"]
