ARG BASE_IMAGE_TAG=uos-server-20-1070a:latest
ARG UOS_BASE=ghcr.io/blueapple168/${BASE_IMAGE_TAG}
FROM ${UOS_BASE} AS builder

LABEL maintainer="blueapple" \
      version="1.0" \
      description="Rust runtime-deps on UOS 1070a" \
      org.opencontainers.image.base.name="registry.uniontech.com/uos-server-base/uos-server-20-1070a:latest"


# ------------------------------
# stage0 openssl‑builder 编译 openssl‑${OPENSSL_VERSION:-3.5.9}(LTS)
# ------------------------------
FROM --platform=linux/amd64 ${UOS_BASE} AS openssl-builder
RUN set -eux; \
    sed -i 's/\$StateMode/ufu/g' /etc/yum.repos.d/UnionTechOS.repo; \
    yum install -y tar gzip gcc make perl diffutils cmake

ENV OPENSSL_VERSION=3.5.9
RUN set -eux; \
    cd /tmp; \
    curl -fsSL https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz -o openssl-${OPENSSL_VERSION}.tar.gz; \
    curl -fsSL https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz.sha256 -o openssl-${OPENSSL_VERSION}.tar.gz.sha256; \
    sha256sum -c openssl-${OPENSSL_VERSION}.tar.gz.sha256; \
    tar -zxf openssl-${OPENSSL_VERSION}.tar.gz; \
    cd openssl-${OPENSSL_VERSION}; \
    ./config --prefix=/usr/local/openssl3 --openssldir=/usr/local/openssl3 shared; \
    make -j$(nproc); \
    make install; \
    cd /; \
    rm -rf /tmp/openssl-${OPENSSL_VERSION} /tmp/openssl-${OPENSSL_VERSION}.tar.gz /tmp/openssl-${OPENSSL_VERSION}.tar.gz.sha256

# ------------------------------
# stage1 ui‑builder：编译前端UI，离线node
# ------------------------------
FROM --platform=linux/amd64 ${UOS_BASE} AS ui-builder
RUN set -eux; \
    sed -i 's/\$StateMode/ufu/g' /etc/yum.repos.d/UnionTechOS.repo; \
    yum install -y tar gzip make
# 离线导入node（构建上下文提供node‑v24.x‑linux‑x64.tar.gz）
ENV NODE_VERSION=v24.21.0
RUN set -eux; \
    cd /opt ; \
    curl -fsSL https://nodejs.org/download/release/latest-v24.x/node-${NODE_VERSION}-linux-x64.tar.gz -o node-${NODE_VERSION}-linux-x64.tar.gz ; \
    curl -fsSL https://nodejs.org/download/release/latest-v24.x/SHASUMS256.txt | grep 'node-${NODE_VERSION}-linux-x64.tar.gz' | sha256sum -c ; \
    tar -xzf node-${NODE_VERSION}-linux-x64.tar.gz; \
    mv node-${NODE_VERSION}-linux-x64 nodejs

ENV PATH="/opt/nodejs/bin:${PATH}"

COPY quickwit/quickwit-ui /quickwit/quickwit-ui
WORKDIR /quickwit/quickwit-ui
RUN touch .gitignore_for_build_directory ; \
    NODE_ENV=production make install build ; \
    rm -rf /opt/node-${NODE_VERSION}-linux-x64.tar.gz /tmp/*


# ------------------------------
# stage2 bin‑builder：rust编译后端quickwit；链接自建openssl3.5.8
# ------------------------------
FROM --platform=linux/amd64 ${UOS_BASE} AS bin-builder
ARG CARGO_FEATURES=release-feature-set
ARG CARGO_PROFILE=release
ARG QW_COMMIT_DATE
ARG QW_COMMIT_HASH
ARG QW_COMMIT_TAGS
ENV QW_COMMIT_DATE=$QW_COMMIT_DATE
ENV QW_COMMIT_HASH=$QW_COMMIT_HASH
ENV QW_COMMIT_TAGS=$QW_COMMIT_TAGS

# 安装系统编译依赖
RUN set -eux; \
    sed -i 's/\$StateMode/ufu/g' /etc/yum.repos.d/UnionTechOS.repo; \
    yum install -y tar findutils gzip clang cmake llvm protobuf-compiler ca-certificates;

# copy openssl编译产物 from openssl‑builder
COPY --from=openssl-builder /usr/local/openssl3 /usr/local/openssl3

RUN set -eux; \
    cd /opt; \
    curl -fsSL https://static.rust-lang.org/dist/rust-1.98.0-x86_64-unknown-linux-musl.tar.gz  -o rust-1.98.0-x86_64-unknown-linux-musl.tar.gz; \
    tar -xzf rust-1.98.0-x86_64-unknown-linux-musl.tar.gz ; \
    cd rust-1.98.0-x86_64-unknown-linux-musl && ./install.sh;
ENV PATH="/root/.cargo/bin:${PATH}"

# 设置openssl环境变量，cargo编译时优先使用自建openssl‑3.5.8
ENV OPENSSL_DIR=/usr/local/openssl3
ENV OPENSSL_LIB_DIR=/usr/local/openssl3/lib64
ENV OPENSSL_INCLUDE_DIR=/usr/local/openssl3/include
ENV LD_LIBRARY_PATH=/usr/local/openssl3/lib64:${LD_LIBRARY_PATH}

COPY quickwit /quickwit
COPY config/quickwit.yaml /quickwit/config/quickwit.yaml
COPY --from=ui-builder /quickwit/quickwit-ui/build /quickwit/quickwit-ui/build

WORKDIR /quickwit

RUN rustup toolchain install

RUN echo "Building workspace with feature(s) '$CARGO_FEATURES' and profile '$CARGO_PROFILE'" \
    && RUSTFLAGS="--cfg tokio_unstable" \
    cargo build \
    -p quickwit-cli \
    --features $CARGO_FEATURES \
    --bin quickwit \
    $(test "$CARGO_PROFILE" = "release" && echo "--release") \
    && echo "Copying binaries to /quickwit/bin" \
    && mkdir -p /quickwit/bin \
    && find target/$CARGO_PROFILE -maxdepth 1 -perm /a+x -type f -exec mv {} /quickwit/bin \;

# ------------------------------
# stage3 final 最终运行镜像(UOS)
# ------------------------------
FROM --platform=linux/amd64 ${UOS_BASE} AS quickwit
ARG UOS_BASE
LABEL org.opencontainers.image.authors="baidongying@cnpc.com.cn" \
      org.opencontainers.image.version="1.0" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.description="Quickwit(UOS‑Server‑1070a)" \
      os="UOS Linux" \
      os.version="${OS_VERSION}"

RUN set -eux; \
    sed -i 's/\$StateMode/ufu/g' /etc/yum.repos.d/UnionTechOS.repo; \
    yum install -y ca-certificates curl findutils; \
    yum clean all; \
    rm -rf /var/cache/yum/* /var/tmp/* /tmp/*

# copy openssl runtime库
COPY --from=openssl-builder /usr/local/openssl3 /usr/local/openssl3
ENV LD_LIBRARY_PATH=/usr/local/openssl3/lib64:${LD_LIBRARY_PATH}

WORKDIR /quickwit
RUN mkdir -p config qwdata

COPY --from=bin-builder /quickwit/bin/quickwit /usr/local/bin/quickwit
COPY --from=bin-builder /quickwit/config/quickwit.yaml /quickwit/config/quickwit.yaml
COPY dumb-init /usr/local/bin/dumb-init

ENV QW_CONFIG=/quickwit/config/quickwit.yaml
ENV QW_DATA_DIR=/quickwit/qwdata
ENV QW_LISTEN_ADDRESS=0.0.0.0

RUN quickwit --version
ENTRYPOINT ["/usr/local/bin/dumb-init", "--", "quickwit"]
CMD ["run"]
