FROM alpine:3.20

# Everything the tuner shells out to. Alpine images are multi-arch, so this
# builds natively on arm64 (Pi 3/4/5 on a 64-bit OS) and armv7 (32-bit OS).
RUN apk add --no-cache \
      bash \
      coreutils \
      procps \
      iproute2 \
      iproute2-tc \
      ethtool \
      iptables \
      iptables-legacy \
      ip6tables \
      kmod \
      iw

COPY tune.sh /usr/local/bin/tune.sh
RUN chmod +x /usr/local/bin/tune.sh

ENTRYPOINT ["/usr/local/bin/tune.sh"]
CMD ["loop"]
