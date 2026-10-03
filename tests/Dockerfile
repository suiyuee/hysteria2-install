FROM debian:13-slim
RUN apt-get update && apt-get install -y --no-install-recommends systemd systemd-sysv dbus openssl shellcheck && rm -rf /var/lib/apt/lists/*
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
