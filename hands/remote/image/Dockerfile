# Build from hands/remote. Both architectures use the same pinned Waymote source.
FROM golang:1.26.5-trixie AS waymote
ARG TARGETARCH
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl git xz-utils libwayland-dev libxkbcommon-dev && rm -rf /var/lib/apt/lists/*
RUN case "$TARGETARCH" in \
      arm64) arch=aarch64; checksum=ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17 ;; \
      amd64) arch=x86_64; checksum=70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00 ;; \
      *) exit 1 ;; \
    esac && curl --fail --location "https://ziglang.org/download/0.16.0/zig-${arch}-linux-0.16.0.tar.xz" -o /tmp/zig.tar.xz \
    && echo "$checksum  /tmp/zig.tar.xz" | sha256sum --check \
    && mkdir /opt/zig && tar -xf /tmp/zig.tar.xz --strip-components=1 -C /opt/zig && rm /tmp/zig.tar.xz
WORKDIR /src/waymote
RUN git init && git remote add origin https://github.com/rockorager/waymote.git \
    && git fetch --depth=1 origin 69f585e6a1dfb84a3ac8135f1a0536aa9d75f6c5 \
    && git checkout --detach FETCH_HEAD
# Distributable images must not inherit the CI runner's CPU extensions (for
# example ARM LSE/SVE unavailable on some supported deployment machines).
RUN /opt/zig/zig build -Dcpu=baseline -Doptimize=ReleaseFast

FROM golang:1.26.5-trixie AS remote
WORKDIR /src/remote
COPY go.mod go.sum ./
RUN go mod download
COPY *.go ./
RUN CGO_ENABLED=0 go build -trimpath -o /out/nanocodex-remote .

FROM debian:trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates labwc foot chromium ffmpeg grim libwayland-client0 libxkbcommon0 \
      dbus-x11 wlr-randr xwayland fonts-dejavu-core curl procps \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --uid 1000 --shell /bin/bash desktop \
    && install -d -o desktop -g desktop -m 0700 /run/nanocodex-desktop \
    && install -d -o desktop -g desktop /workspace
COPY --from=waymote /src/waymote/zig-out/bin/waymote-streamd /usr/local/bin/waymote-streamd
COPY --from=remote /out/nanocodex-remote /usr/local/bin/nanocodex-remote
COPY image/labwc /etc/nanocodex-desktop
ENV WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_HEADLESS_OUTPUTS=1 \
    XDG_RUNTIME_DIR=/run/nanocodex-desktop WAYLAND_DISPLAY=wayland-0 \
    XDG_SESSION_TYPE=wayland XDG_CURRENT_DESKTOP=labwc
USER desktop
WORKDIR /workspace
ENTRYPOINT ["labwc", "--config-dir", "/etc/nanocodex-desktop"]
