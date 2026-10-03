#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."

unit_checks() (
  source hysteria.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
for domain in example.com hy.example.com; do valid_domain "$domain"; done
for domain in '-a.example.com' 'a..example.com' '127.0.0.1' 'https://example.com' 'x.com:443'; do
  if valid_domain "$domain"; then echo "accepted invalid domain: $domain"; exit 1; fi
done
printf '{}\n' > "$work/old"
prepare_config "$work/old" "$work/new" hy.example.com '' 443 '' false
jq -e '.auth.password|length==64' "$work/new" >/dev/null
jq -e '.acme | has("email") | not' "$work/new" >/dev/null
prepare_config "$work/old" "$work/explicit" hy.example.com user@example.com 443 '' false
jq -e '.acme.email=="user@example.com"' "$work/explicit" >/dev/null
prepare_config "$work/explicit" "$work/preserved" hy.example.com '' 443 '' false
jq -e '.acme.email=="user@example.com"' "$work/preserved" >/dev/null
prepare_config "$work/old" "$work/second" hy.example.com '' 443 '' false
[[ $(jq -r .auth.password "$work/new") != "$(jq -r .auth.password "$work/second")" ]]
jq '.auth.password="a:@/# ?\"\n汉字" | .listen=":63992" | .quic={maxIdleTimeout:"40s"} | .obfs={type:"salamander",salamander:{password:"b &?="}} | .acme.ca="zerossl" | .masquerade={type:"string",string:{content:"custom"}}' "$work/new" > "$work/old"
prepare_config "$work/old" "$work/new" hy.example.com '' 63992 '' false
for key in auth quic obfs acme masquerade; do
 [[ $(jq -c ".$key" "$work/old") == "$(jq -c ".$key" "$work/new")" ]]
done
export_client "$work/new" "$work"
jq -e --slurpfile old "$work/old" '.proxies[0].password==$old[0].auth.password and .proxies[0]["skip-cert-verify"]==false and .proxies[0]["obfs-password"]==$old[0].obfs.salamander.password' "$work/clash.yaml" >/dev/null
grep -Fq 'obfs-password=b%20%26%3F%3D' "$work/hy2.txt"
if verify_binary "$work/new" "sha256:$(printf '%064d' 0)"; then echo 'wrong checksum accepted'; exit 1; fi
bash hysteria.sh --help >/dev/null
if bash hysteria.sh upgrade --domain hy.example.com --dry-run >/dev/null 2>&1; then exit 1; fi
if bash hysteria.sh --domain bad --dry-run >/dev/null 2>&1; then exit 1; fi
printf 'PASS configuration preservation, credential escaping, validation and checksum rejection\n'
)

# Only invoked inside the disposable Debian 13 container below.
integration_checks() (
[[ ${HY2_DISPOSABLE_VM:-} == yes && $EUID == 0 ]] || exit 1
[[ ! -e /etc/hysteria/config.yaml && ! -e /usr/local/bin/hysteria ]] || { echo 'Refusing existing installation'; exit 1; }
if command -v python3; then echo "Unexpected Python runtime"; exit 1; fi
cd /repo
scratch=$(mktemp -d /root/hy2-test-XXXXXXXX)
client_pid=''
trap '[[ -z $client_pid ]] || kill "$client_pid" 2>/dev/null || true; rm -rf "$scratch"' EXIT
ip=$(hostname -I); ip=${ip%% *}
domain=hy2.integration.test
printf '\n%s %s\n' "$ip" "$domain" >> /etc/hosts
useradd --system --user-group --home-dir /var/lib/hysteria --shell /usr/sbin/nologin hysteria
cert_dir=/var/lib/hysteria/acme/certificates/acme-v02.api.letsencrypt.org-directory/$domain
mkdir -p "$cert_dir"
openssl req -x509 -newkey rsa:2048 -nodes -days 90 -subj "/CN=$domain" -addext "subjectAltName=DNS:$domain" -keyout "$cert_dir/$domain.key" -out "$cert_dir/$domain.crt" 2>/dev/null
printf '{"sans":["%s"],"issuer_data":{}}\n' "$domain" > "$cert_dir/$domain.json"
chown -R hysteria:hysteria /var/lib/hysteria
sha256sum "$cert_dir/$domain.crt" > "$scratch/cert.sha"
bash hysteria.sh --domain "$domain" --port 24443 --non-interactive > "$scratch/install.log" 2>&1 || { cat "$scratch/install.log"; exit 1; }
if command -v python3; then echo "Unexpected Python runtime"; exit 1; fi
[[ $(stat -c '%U:%G:%a' /etc/hysteria/config.yaml) == root:hysteria:640 ]]
[[ $(stat -c %a /etc/hysteria/client/clash.yaml) == 600 ]]
jq -e '.proxies[0]["skip-cert-verify"]==false' /etc/hysteria/client/clash.yaml >/dev/null
printf 'PASS fresh install on Debian 13 without Python; permissions and exports\n'
bash tests/check.sh
LANG=C.UTF-8 shellcheck -x hysteria.sh tests/check.sh

jq --arg cert "$cert_dir/$domain.crt" '{server:(.acme.domains[0]+":24443"),auth:.auth.password,tls:{sni:.acme.domains[0],ca:$cert},socks5:{listen:"127.0.0.1:21080"}}' /etc/hysteria/config.yaml > "$scratch/client.json"
/usr/local/bin/hysteria client -c "$scratch/client.json" > "$scratch/client.log" 2>&1 & client_pid=$!
for ((i=0;i<30;i++)); do
 if [[ -n $(ss -Hltn 'sport = :21080') ]]; then break; fi
 sleep .2
done
curl -fsS --max-time 30 --proxy socks5h://127.0.0.1:21080 https://www.gstatic.com/generate_204 >/dev/null
kill "$client_pid"; wait "$client_pid" || true; client_pid=''
printf 'PASS real QUIC proxy with certificate verification\n'

config=/etc/hysteria/config.yaml
jq '.masquerade={type:"string",string:{content:"keep-custom"}} | .quic={maxIdleTimeout:"40s"}' "$config" > "$scratch/custom"
install -o root -g hysteria -m 640 "$scratch/custom" "$config"
sha256sum /usr/local/bin/hysteria > "$scratch/binary.sha"
cp "$config" "$scratch/before"
bash hysteria.sh --non-interactive > "$scratch/reconfigure.log" 2>&1 || { cat "$scratch/reconfigure.log"; exit 1; }
sha256sum -c "$scratch/cert.sha" "$scratch/binary.sha"
for field in auth listen masquerade quic acme; do
 [[ $(jq -c ".$field" "$config") == "$(jq -c ".$field" "$scratch/before")" ]]
done
sha256sum "$config" /etc/hysteria/client/clash.yaml /etc/systemd/system/hysteria-server.service > "$scratch/state.sha"
bash hysteria.sh upgrade --non-interactive > "$scratch/upgrade.log" 2>&1 || { cat "$scratch/upgrade.log"; exit 1; }
sha256sum -c "$scratch/state.sha"
printf 'PASS repeat deployment preserves settings/certificate; upgrade leaves config untouched\n'

# Inject a failed formal switch and exercise the exact production EXIT rollback.
cat > "$scratch/rollback.sh" <<'ROLLBACK'
#!/usr/bin/env bash
source /repo/hysteria.sh
umask 077
work=$(mktemp -d)
backup=$(mktemp -d /root/hy2-backup-test-XXXXXXXX)
transaction=true had_unit=true was_active=true stage=''
targets=() existed=() pending=()
trap cleanup EXIT
printf '{"listen":":24443","tls":{"cert":"/missing","key":"/missing"}}' > "$work/broken"
replace_file "$work/broken" "$CONFIG" 640 hysteria
systemctl restart hysteria-server
wait_ready hysteria-server 15
ROLLBACK
if bash "$scratch/rollback.sh" > "$scratch/rollback.log" 2>&1; then echo 'Invalid config accepted'; exit 1; fi
grep -q '已恢复部署前文件及服务状态' "$scratch/rollback.log" || { cat "$scratch/rollback.log"; exit 1; }
sha256sum -c "$scratch/state.sha"
[[ $(stat -c '%U:%G:%a' "$config") == root:hysteria:640 ]]
systemctl is-active --quiet hysteria-server
printf 'PASS failed switch restores content, ownership, permissions and service\n'
if command -v python3; then echo "Unexpected Python runtime"; exit 1; fi
printf 'ALL DEBIAN 13 BASH CHECKS PASSED\n'
)

container_checks() (
name="hy2-debian13-$$"
trap 'docker rm -f "$name" >/dev/null 2>&1 || true' EXIT
docker build -t hy2-debian13-test -f - . <<'DOCKERFILE'
FROM debian:13-slim
RUN apt-get update && apt-get install -y --no-install-recommends systemd systemd-sysv dbus openssl shellcheck && rm -rf /var/lib/apt/lists/*
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
DOCKERFILE
docker run -d --name "$name" --privileged --cgroupns=host \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run --tmpfs /run/lock \
  -v "$PWD:/repo:ro" hy2-debian13-test
for ((i=0;i<30;i++)); do
 if docker exec "$name" test -d /run/systemd/system; then break; fi
 sleep 1
done
docker exec -e HY2_DISPOSABLE_VM=yes "$name" bash /repo/tests/check.sh --integration
)

case ${1:-} in
  '') unit_checks ;;
  --container) container_checks ;;
  --integration) integration_checks ;;
  *) echo '用法：bash tests/check.sh [--container]' >&2; exit 1 ;;
esac
