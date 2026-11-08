FROM alpine:3.20

RUN apk add --no-cache bash coreutils iputils python3 \
 && python3 -m venv /opt/speedtest \
 && /opt/speedtest/bin/pip install --no-cache-dir speedtest-cli==2.1.3

COPY monitor.sh /usr/local/bin/monitor.sh
RUN chmod +x /usr/local/bin/monitor.sh

VOLUME ["/data"]
ENTRYPOINT ["/usr/local/bin/monitor.sh"]
CMD ["loop"]
