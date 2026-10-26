FROM golang:bookworm AS hey-builder
RUN CGO_ENABLED=0 go install github.com/rakyll/hey@v0.1.5

WORKDIR /go/pkg/mod/github.com/rakyll/hey@v0.1.5
# Keep the bounded initial allocation, but retain every response for full-window p95.
RUN sed -i '/if len(r.resLats) < maxRes {/d; /r.offsets = append(r.offsets, res.offset.Seconds())/{n;d;}' requester/report.go \
    && gofmt -w requester/report.go \
    && CGO_ENABLED=0 go build -o /go/bin/hey .

FROM rubylang/ruby:master-dev

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8
ENV RUBY_YJIT_ENABLE=1

RUN apt-get update && apt-get install -y --no-install-recommends \
      clang \
      libbpf-dev \
      libelf-dev \
      libssl-dev \
      libyaml-dev \
      linux-libc-dev \
      nghttp2 \
      openssl \
    && rm -rf /var/lib/apt/lists/*

COPY --from=hey-builder /go/bin/hey /usr/local/bin/hey

ENV BUNDLE_PATH=/workspace/.bundle
ENV BUNDLE_APP_CONFIG=/workspace/.bundle
ENV PATH=/workspace/bin:${PATH}

WORKDIR /workspace

CMD ["bash"]
