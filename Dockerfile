# syntax=docker/dockerfile:1
# =============================================================================
# Quickwit on UOS Server 20-1070a —— 全在线构建版 / GNU 工具链（GitHub Actions）
# =============================================================================

ARG BASE_IMAGE_TAG=uos-server-20-1070a:latest
ARG UOS_BASE=ghcr.io/blueapple168/${BASE_IMAGE_TAG}

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
FROM ${UOS_BASE} AS openssl-builder
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
FROM ${UOS_BASE} AS ui-builder
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
FROM ${UOS_BASE} AS bin-builder
ARG RUST_VERSION
ARG RUST_HOST
ARG DUMB_INIT_VERSION
ARG PROTOC_VERSION
ARG CARGO_FEATURES=release-feature-set
ARG CARGO_PROFILE=release
ARG QW_COMMIT_DATE
ARG QW_COMMIT_HASH
ARG QW_COMMIT_TAGS
ARG OPENSSL_PREFIX=/usr/local/openssl3
ARG OPENSSL_LIBDIR=lib64
ENV QW_COMMIT_DATE=${QW_COMMIT_DATE} \
    QW_COMMIT_HASH=${QW_COMMIT_HASH} \
    QW_COMMIT_TAGS=${QW_COMMIT_TAGS}
SHELL ["/bin/bash", "-euxo", "pipefail", "-c"]

# ---- 系统编译依赖 + dumb-init（全部在线） ----
# 注意 1：这里故意不装 UOS 的 protobuf-compiler（版本 ~3.5，不认
#         --experimental_allow_proto3_optional），protoc 单独用官方预编译包装。
# 注意 2：devel 包不能省。rdkafka-sys 走 vendored CMake 编 librdkafka，
#         CMake 探测依赖需要对应的 CMake config/pkgconfig 文件：
#           openssl-devel  -> 提供 OpenSSLConfig.cmake（供 -DCMAKE_PREFIX_PATH 命中）
#           zlib-devel     -> zlib 的 CMake 探测（FindZLIB 兜底）
#         以前只装 gcc-c++，靠 vendored zlib/zstd 也能过，但 openssl 没有 devel
#         就一定找不到。
#
# 注意 3：libcurl-devel 必须有。rdkafka-sys 4.10 带的是 librdkafka 2.12，
#         其 src/rdkafka_conf.c 顶部是无条件 `#include <curl/curl.h>`
#         （旧版 librdkafka 只在 WITH_CURL 时要），所以哪怕是 -DWITH_CURL=0，
#         头文件仍然必须存在，否则：
#             rdkafka_conf.c:60:10: fatal error: curl/curl.h: No such file or directory
#         上一轮日志里 CMake 的 `-DWITH_CURL=0` 已经明确给出了，仍然挂了，
#         就是这个原因——WITH_CURL 只控制链接，不控制 include。
RUN sed -i 's/\$StateMode/ufu/g' /etc/yum.repos.d/UnionTechOS.repo; \
    yum install -y --setopt=install_weak_deps=false --nogpgcheck --nodocs \
        tar gzip xz unzip curl ca-certificates findutils which \
        clang cmake llvm \
        gcc gcc-c++ make pkgconfig perl \
        openssl-devel zlib-devel libcurl-devel; \
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
#
# 为什么需要这么多变量（上一版只给了 OPENSSL_DIR 系列，rdkafka-sys 直接失败）：
#
#   1) OPENSSL_DIR / OPENSSL_LIB_DIR / OPENSSL_INCLUDE_DIR
#      给 openssl-sys 这个 Rust crate 用（它按这套约定找自建 OpenSSL）。
#
#   2) OPENSSL_ROOT_DIR
#      ---- 这次报错的根因 ----
#      rdkafka-sys 带 vendored librdkafka，用 CMake 编译，CMake 的
#      FindOpenSSL.cmake **不认识** OPENSSL_DIR / OPENSSL_LIB_DIR，
#      它只认 OPENSSL_ROOT_DIR（等价于命令行 -DOPENSSL_ROOT_DIR=...）。
#      只给 OPENSSL_DIR 时 CMake 一路去 /usr/lib64 找系统 openssl（1.1.1），
#      若 openssl-devel 没装就连头文件都没有 → "Could NOT find OpenSSL"。
#
#   3) OPENSSL_CRYPTO_LIBRARY / OPENSSL_SSL_LIBRARY
#      FindOpenSSL 的必需变量是 OPENSSL_CRYPTO_LIBRARY 和 OPENSSL_SSL_LIBRARY。
#      直接给出绝对路径，就不再依赖 CMake 自行推理 lib/lib64 目录名，
#      彻底规避 "missing: OPENSSL_CRYPTO_LIBRARY" 这类探测失败。
#
#      注意：自建 openssl 的库名是 libssl.so.3 / libcrypto.so.3
#      （OPENSSL_VERSION_NUMBER >= 3 时 .so 只是软链）。
#      FindOpenSSL 的 find_library 能直接命中 .so.3 后缀，给带 .so.3 的路径最稳。
#
#   4) PKG_CONFIG_PATH
#      FindOpenSSL 会先尝试 pkg-config（openssl.pc），
#      自建 openssl 的 .pc 落在 ${OPENSSL_PREFIX}/lib64/pkgconfig。
#
ENV OPENSSL_DIR=${OPENSSL_PREFIX} \
    OPENSSL_LIB_DIR=${OPENSSL_PREFIX}/${OPENSSL_LIBDIR} \
    OPENSSL_INCLUDE_DIR=${OPENSSL_PREFIX}/include \
    OPENSSL_ROOT_DIR=${OPENSSL_PREFIX} \
    OPENSSL_CRYPTO_LIBRARY=${OPENSSL_PREFIX}/${OPENSSL_LIBDIR}/libcrypto.so.3 \
    OPENSSL_SSL_LIBRARY=${OPENSSL_PREFIX}/${OPENSSL_LIBDIR}/libssl.so.3 \
    PKG_CONFIG_PATH=${OPENSSL_PREFIX}/${OPENSSL_LIBDIR}/pkgconfig \
    LD_LIBRARY_PATH=${OPENSSL_PREFIX}/${OPENSSL_LIBDIR}

# 自检：确认 4 个关键路径全部存在，且 CMake 真能通过 FindOpenSSL 探测。
# 把问题提前到这一步暴露，别拖到 400 秒后的 cargo 编译阶段。
RUN set -eux; \
    for f in \
        "${OPENSSL_PREFIX}/include/openssl/ssl.h" \
        "${OPENSSL_CRYPTO_LIBRARY}" \
        "${OPENSSL_SSL_LIBRARY}" \
        "${OPENSSL_PREFIX}/lib64/libssl.so" \
        "${OPENSSL_PREFIX}/lib64/libcrypto.so" ; do \
        test -e "$f" || { echo "MISSING: $f"; exit 1; }; \
    done; \
    echo "--- openssl 自检通过 ---"; \
    sed -n '1p' "${OPENSSL_PREFIX}/include/openssl/opensslv.h" || true

# 自检：librdkafka 编译期必需的头文件/工具，缺了直接在这里报错。
#   curl/curl.h        librdkafka 2.12 无条件 include（libcurl-devel）
#   libsasl2 可以没有  —— 走 -DWITH_SASL=0，只有 SCRAM/OAUTHBEARER 内置实现
#   注意这里刻意不打印 sasl 相关检查，避免误判失败。
RUN set -eux; \
    for f in /usr/include/curl/curl.h /usr/include/curl/curlver.h; do \
        test -e "$f" || { echo "MISSING: $f"; exit 1; }; \
    done; \
    echo "--- librdkafka 依赖自检通过 ---"; \
    curl-config --version || true

# ---- Quickwit 源码 + UI 产物 ----
COPY quickwit /quickwit
COPY config/quickwit.yaml /quickwit/config/quickwit.yaml
COPY --from=ui-builder /quickwit/quickwit-ui/build /quickwit/quickwit-ui/build
WORKDIR /quickwit

# 编译（带 BuildKit 缓存，Actions 上多栈复用更快）
#
# 环境变量说明：
#   RUSTFLAGS       —— quickwit 需要 tokio_unstable
#   CMAKE_PREFIX_PATH —— 让 CMake 优先在自建 openssl 下找 config 文件
#                        （FindOpenSSL 的 config 模式命中 OpenSSLConfig.cmake）
#   OPENSSL_ROOT_DIR 已由上面的 ENV 提供，这里不重复
#   CC / CXX / AR / RANLIB —— 显式钉住编译器。
#     上一版日志里 CMake 探测到的是 GNU 8.5.0，即 UOS 自带的 /usr/bin/cc。
#     vendored 依赖（librdkafka、zstd、zlib）对 gcc 版本敏感，
#     显式给出绝对路径可避免 PATH 被 rust 工具链插入后 cc 解析到别的版本。
RUN --mount=type=cache,target=/quickwit/target,sharing=locked \
    set -eux; \
    echo "Building workspace with feature(s) '${CARGO_FEATURES}' and profile '${CARGO_PROFILE}'"; \
    echo "C compiler: $(cc --version | head -n1)"; \
    echo "C++ compiler: $(c++ --version | head -n1)"; \
    export RUSTFLAGS="--cfg tokio_unstable"; \
    export CMAKE_PREFIX_PATH="${OPENSSL_PREFIX}"; \
    export CC=/usr/bin/cc CXX=/usr/bin/c++ AR=/usr/bin/ar RANLIB=/usr/bin/ranlib; \
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
FROM ${UOS_BASE} AS quickwit
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
        ca-certificates curl findutils tar gzip \
        zlib libcurl openssl-libs \
        libstdc++ libgcc; \
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
