FROM golang:bookworm AS hey-builder
RUN CGO_ENABLED=0 go install github.com/rakyll/hey@latest

FROM ruby:latest

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8
ENV RUBY_YJIT_ENABLE=1

RUN apt-get update && apt-get install -y --no-install-recommends \
      nghttp2 \
      openssl \
    && rm -rf /var/lib/apt/lists/*

COPY --from=hey-builder /go/bin/hey /usr/local/bin/hey

ENV BUNDLE_PATH=/workspace/.bundle
ENV BUNDLE_APP_CONFIG=/workspace/.bundle
ENV PATH=/workspace/bin:${PATH}

WORKDIR /workspace

CMD ["bash"]
