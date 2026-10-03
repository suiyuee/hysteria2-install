#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
name="hy2-debian13-$$"
trap 'docker rm -f "$name" >/dev/null 2>&1 || true' EXIT
docker build -t hy2-debian13-test -f tests/Dockerfile .
docker run -d --name "$name" --privileged --cgroupns=host \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run --tmpfs /run/lock \
  -v "$PWD:/repo:ro" hy2-debian13-test
for ((i=0;i<30;i++)); do
 if docker exec "$name" test -d /run/systemd/system; then break; fi
 sleep 1
done
docker exec -e HY2_DISPOSABLE_VM=yes "$name" bash /repo/tests/linux-integration.sh
