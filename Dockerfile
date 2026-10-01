# syntax=docker/dockerfile:1
# =============================================================================
# Quickwit on UOS Server 20-1070a —— 全在线构建版 / GNU 工具链（GitHub Actions）
# =============================================================================

ARG BASE_IMAGE_TAG=uos-server-20-1070a:latest
ARG UOS_BASE=ghcr.io/blueapple168/${BASE_IMAGE_TAG}
# 目标平台：UOS 基础镜像只提供 amd64。
# 做成 ARG 可覆盖，同时消除 FROM --platform 常量告警（FromPlatformFlagConstDisallowed）。
ARG TARGETPLATFORM=linux/amd64

# 全局构建参数（可被 GitHub Actions 覆盖）
ARG OPENSSL_VERSION=3.5.9
ARG RUST_VERSION=1.98.0
ARG RUST_HOST=x86_64-unknown-linux-gnu
ARG NODE_VERSION=v24.21.0
ARG DUMB_INIT_VERSION=1.2.5
# protoc 版本：必须 >= 3.12 才支持 --experimental_allow_proto3_optional，
# UOS 仓库自带的 protobuf-compiler（~3.5）太老会直接报 Unknown flag。
ARG PROTOC_VERSION=25.6


# =============================================================================
# stage0  openssl-builder —— 编译 OpenSSL ${OPENSSL_VERSION} (LTS)
# =============================================================================
FROM --platform=$TARGETPLATFORM ${UOS_BASE} AS openssl-builder
ARG OPENSSL_VERSION
SHELL ["/bin/bash", "-euxo", "pipefail", "-c"]

RUN sed -i 's/\$StateMode/ufu/g' /etc/yum.repos.d/UnionTechOS.repo; \
    yum install -y --setopt=install_weak_deps=false --nogpgcheck --nodocs \
        tar gzip curl ca-certificates findutils gcc make perl diffutils; \
    yum clean all; rm -rf /var/cache/yum/*

RUN cd /tmp; \
    curl -fsSL "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz" \
         -o "openssl-${OPENSSL_VERSION}.tar.gz"; \
    curl -fsSL "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz.sha256" \
         -o "openssl-${OPENSSL_VERSION}.tar.gz.sha256"; \
    sha256sum -c "openssl-${OPENSSL_VERSION}.tar.gz.sha256"; \
    tar -zxf "openssl-${OPENSSL_VERSION}.tar.gz"; \
    cd "openssl-${OPENSSL_VERSION}"; \
    ./config --prefix=/usr/local/openssl3 --openssldir=/usr/local/openssl3 shared; \
    make -j"$(nproc)"; \
    make install_sw install_ssldirs; \
    cd /; \
    rm -rf /tmp/openssl-${OPENSSL_VERSION} /tmp/openssl-${OPENSSL_VERSION}.tar.gz*


# =============================================================================
# stage1  ui-builder —— 编译前端 UI（在线装 Node）
# =============================================================================
FROM --platform=$TARGETPLATFORM ${UOS_BASE} AS ui-builder
ARG NODE_VERSION
SHELL ["/bin/bash", "-euxo", "pipefail", "-c"]

RUN sed -i 's/\$StateMode/ufu/g' /etc/yum.repos.d/UnionTechOS.repo; \
    yum install -y --setopt=install_weak_deps=false --nogpgcheck --nodocs \
        tar gzip xz curl ca-certificates findutils make gcc gcc-c++ python3; \
    yum clean all; rm -rf /var/cache/yum/*

RUN cd /opt; \
    curl -fsSL "https://nodejs.org/download/release/latest-v24.x/node-${NODE_VERSION}-linux-x64.tar.gz" \
         -o "node-${NODE_VERSION}-linux-x64.tar.gz"; \
    curl -fsSL "https://nodejs.org/download/release/latest-v24.x/SHASUMS256.txt" \
       | grep "node-${NODE_VERSION}-linux-x64.tar.gz" \
       | sha256sum -c -; \
    tar -xzf "node-${NODE_VERSION}-linux-x64.tar.gz"; \
    mv "node-${NODE_VERSION}-linux-x64" nodejs; \
    rm -f "node-${NODE_VERSION}-linux-x64.tar.gz"

ENV PATH="/opt/nodejs/bin:${PATH}"

# yarn / node-gyp 走在线源
RUN npm config set registry https://registry.npmmirror.com; \
    npm install -g yarn node-gyp; \
    node --version; npm --version; yarn --version

COPY quickwit/quickwit-ui /quickwit/quickwit-ui
WORKDIR /quickwit/quickwit-ui
RUN touch .gitignore_for_build_directory; \
    NODE_ENV=production make install build; \
    rm -rf /tmp/*


# =============================================================================
# stage2  bin-builder —— Rust 编译 Quickwit，链接自建 OpenSSL
# =============================================================================
FROM --platform=$TARGETPLATFORM ${UOS_BASE} AS bin-builder
ARG RUST_VERSION
ARG RUST_HOST
ARG DUMB_INIT_VERSION
ARG PROTOC_VERSION
ARG CARGO_FEATURES=release-feature-set
ARG CARGO_PROFILE=release
ARG QW_COMMIT_DATE
ARG QW_COMMIT_HASH
ARG QW_COMMIT_TAGS
ENV QW_COMMIT_DATE=${QW_COMMIT_DATE} \
    QW_COMMIT_HASH=${QW_COMMIT_HASH} \
    QW_COMMIT_TAGS=${QW_COMMIT_TAGS}
SHELL ["/bin/bash", "-euxo", "pipefail", "-c"]

# ---- 系统编译依赖 + dumb-init（全部在线） ----
# 注意：这里故意不装 UOS 的 protobuf-compiler（版本 ~3.5，不认
#       --experimental_allow_proto3_optional），protoc 单独用官方预编译包装。
RUN sed -i 's/\$StateMode/ufu/g' /etc/yum.repos.d/UnionTechOS.repo; \
    yum install -y --setopt=install_weak_deps=false --nogpgcheck --nodocs \
        tar gzip xz unzip curl ca-certificates findutils \
        clang cmake llvm \
        gcc gcc-c++ make pkgconfig perl; \
    yum clean all; rm -rf /var/cache/yum/*; \
    curl -fsSL "https://github.com/Yelp/dumb-init/releases/download/v${DUMB_INIT_VERSION}/dumb-init_${DUMB_INIT_VERSION}_x86_64" \
         -o /usr/local/bin/dumb-init; \
    chmod +x /usr/local/bin/dumb-init

# ---- protoc（官方预编译包，替换 UOS 的老版本） ----
# 背景：Quickwit 的 quickwit-proto/build.rs 通过 prost-build 调 protoc 时传了
#       --experimental_allow_proto3_optional，该 flag 需要 protoc >= 3.12。
#       UOS 1070a 仓库里的 protobuf-compiler 约 3.5，会报 "Unknown flag" 直接 panic。
#       官方 zip 内为 bin/protoc + include/google/protobuf/*（well-known types 齐全）。
RUN curl -fsSL "https://github.com/protocolbuffers/protobuf/releases/download/v${PROTOC_VERSION}/protoc-${PROTOC_VERSION}-linux-x86_64.zip" \
         -o /tmp/protoc.zip; \
    unzip -q /tmp/protoc.zip -d /usr/local; \
    chmod 755 /usr/local/bin/protoc; \
    rm -f /tmp/protoc.zip; \
    /usr/local/bin/protoc --version
# prost-build 优先读 PROTOC 环境变量，显式指过去最稳
ENV PROTOC=/usr/local/bin/protoc

# ---- OpenSSL 编译产物 ----
COPY --from=openssl-builder /usr/local/openssl3 /usr/local/openssl3

# ---- Rust host 工具链（在线安装，gnu 版） ----
# 注意：tarball 里的 install.sh 是 rust-installer v3，
#       没有 --yes / --force 这类选项，传了会 "Option '--yes' is not recognized" 直接失败。
#       用 --disable-ldconfig 跳过它对 ld.so.conf 的写入，避免污染。
RUN cd /opt; \
    curl -fsSL "https://static.rust-lang.org/dist/rust-${RUST_VERSION}-${RUST_HOST}.tar.gz" \
         -o "rust-${RUST_VERSION}-${RUST_HOST}.tar.gz"; \
    tar -xzf "rust-${RUST_VERSION}-${RUST_HOST}.tar.gz"; \
    cd "rust-${RUST_VERSION}-${RUST_HOST}"; \
    ./install.sh --prefix=/usr/local --disable-ldconfig --verbose; \
    cd /; \
    rm -rf "/opt/rust-${RUST_VERSION}-${RUST_HOST}" "/opt/rust-${RUST_VERSION}-${RUST_HOST}.tar.gz"

# tarball 装到 /usr/local/bin（不是 rustup 的 ~/.cargo/bin）
ENV PATH="/usr/local/bin:${PATH}"

# 自检：工具链能真的跑起来才算装好（gnu 版直接依赖系统 glibc，无需补 loader）
RUN rustc --version && cargo --version && rustc -vV

# ---- OpenSSL 环境变量：cargo 编译优先用自建 openssl-3.5.9 ----
ENV OPENSSL_DIR=/usr/local/openssl3 \
    OPENSSL_LIB_DIR=/usr/local/openssl3/lib64 \
    OPENSSL_INCLUDE_DIR=/usr/local/openssl3/include \
    LD_LIBRARY_PATH=/usr/local/openssl3/lib64

# ---- Quickwit 源码 + UI 产物 ----
COPY quickwit /quickwit
COPY config/quickwit.yaml /quickwit/config/quickwit.yaml
COPY --from=ui-builder /quickwit/quickwit-ui/build /quickwit/quickwit-ui/build
WORKDIR /quickwit

# 编译（带 BuildKit 缓存，Actions 上多栈复用更快）
RUN --mount=type=cache,target=/quickwit/target,sharing=locked \
    set -eux; \
    echo "Building workspace with feature(s) '${CARGO_FEATURES}' and profile '${CARGO_PROFILE}'"; \
    export RUSTFLAGS="--cfg tokio_unstable"; \
    cargo build \
        -p quickwit-cli \
        --features "${CARGO_FEATURES}" \
        --bin quickwit \
        $(test "${CARGO_PROFILE}" = "release" && echo "--release"); \
    mkdir -p /quickwit/bin; \
    find "target/${CARGO_PROFILE}" -maxdepth 1 -perm /a+x -type f -exec mv {} /quickwit/bin/ \;


# =============================================================================
# stage3  最终运行镜像（UOS）
# =============================================================================
FROM --platform=$TARGETPLATFORM ${UOS_BASE} AS quickwit
ARG BASE_IMAGE_TAG
LABEL org.opencontainers.image.authors="blueapple" \
      org.opencontainers.image.version="1.0" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.description="Quickwit(UOS-Server-1070a)" \
      os="UOS Linux" \
      os.version="${BASE_IMAGE_TAG}"
SHELL ["/bin/bash", "-euxo", "pipefail", "-c"]

RUN sed -i 's/\$StateMode/ufu/g' /etc/yum.repos.d/UnionTechOS.repo; \
    yum install -y --setopt=install_weak_deps=false --nogpgcheck --nodocs \
        ca-certificates curl findutils tar gzip; \
    yum clean all; \
    rm -rf /var/cache/yum/* /var/tmp/* /tmp/*

# OpenSSL 运行时库
COPY --from=openssl-builder /usr/local/openssl3 /usr/local/openssl3
ENV LD_LIBRARY_PATH=/usr/local/openssl3/lib64

WORKDIR /quickwit
RUN mkdir -p config qwdata

COPY --from=bin-builder /quickwit/bin/quickwit /usr/local/bin/quickwit
COPY --from=bin-builder /quickwit/config/quickwit.yaml /quickwit/config/quickwit.yaml
COPY --from=bin-builder /usr/local/bin/dumb-init /usr/local/bin/dumb-init
RUN chmod 755 /usr/local/bin/dumb-init /usr/local/bin/quickwit

ENV QW_CONFIG=/quickwit/config/quickwit.yaml \
    QW_DATA_DIR=/quickwit/qwdata \
    QW_LISTEN_ADDRESS=0.0.0.0

RUN quickwit --version

EXPOSE 7280 7281
ENTRYPOINT ["/usr/local/bin/dumb-init", "--", "quickwit"]
CMD ["run"]
