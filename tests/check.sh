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
jq -e '.listen=="0.0.0.0:443" and .outbounds[0].direct.mode=="4"' "$work/new" >/dev/null
# Migrate an old dual-stack listener without losing ACL outbound names or tuning.
jq '.listen="[::]:443" | .outbounds=[{name:"existing",type:"direct",direct:{mode:"64",bindIPv6:"2001:db8::1",fastOpen:true}}]' "$work/new" > "$work/dual"
prepare_config "$work/dual" "$work/ipv4" hy.example.com '' 443 '' false
jq -e '.listen=="0.0.0.0:443" and .outbounds[0].name=="existing" and .outbounds[0].direct.mode=="4" and .outbounds[0].direct.fastOpen and (.outbounds[0].direct|has("bindIPv6")|not)' "$work/ipv4" >/dev/null

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
export_client "$work" "$work/new"
jq -e --slurpfile old "$work/old" '.proxies[0].password==$old[0].auth.password and .proxies[0]["skip-cert-verify"]==false and .proxies[0]["obfs-password"]==$old[0].obfs.salamander.password' "$work/clash.yaml" >/dev/null
grep -Fq 'obfs-password=b%20%26%3F%3D' "$work/hy2.txt"
jq -e '.ipv6==false and .dns.ipv6==false and .proxies[0]["ip-version"]=="ipv4" and .proxies[0].name=="hy.example.com"' "$work/clash.yaml" >/dev/null
# DNS must point only to local IPv4, including on a dual-stack host.
(
  ip() { printf '%s\n' '[{"addr_info":[{"scope":"global","family":"inet","local":"192.0.2.1"},{"scope":"global","family":"inet6","local":"2001:db8::1"}]}]'; }
  getent() { printf '192.0.2.1 STREAM\n'; }
  dns_check hy.example.com 0
  getent() { printf '192.0.2.1 STREAM\n2001:db8::1 STREAM\n'; }
  if (dns_check hy.example.com 0) >/dev/null 2>&1; then echo 'accepted AAAA record'; exit 1; fi
)

# Multiple IPv4 nodes: each binds listen, ACME and direct egress to its own IP.
printf '{}\n' > "$work/empty"
prepare_config "$work/empty" "$work/b" hy-b.example.com '' 443 '' false
jq '.outbounds[0].direct.bindDevice="eth0"' "$work/b" > "$work/b-dev"
node_config "$work/b-dev" "$work/b-ip" 192.0.2.2
jq -e '.listen=="192.0.2.2:443" and .acme.listenHost=="192.0.2.2" and .outbounds[0].direct.bindIPv4=="192.0.2.2"
  and .outbounds[0].direct.mode=="4" and (.outbounds[0].direct|has("bindDevice")|not)' "$work/b-ip" >/dev/null
node_config "$work/new" "$work/a-ip" 192.0.2.1
export_client "$work" "$work/a-ip" "$work/b-ip"
jq -e '(.proxies|map(.name))==["hy.example.com","hy-b.example.com"] and (.proxies|map(.port))==[63992,443]
  and .["proxy-groups"][0].proxies==["hy.example.com","hy-b.example.com","DIRECT"] and all(.proxies[];.["ip-version"]=="ipv4")' "$work/clash.yaml" >/dev/null
[[ $(grep -c '^hysteria2://' "$work/hy2.txt") == 2 ]] && grep -q '@hy-b.example.com:443/' "$work/hy2.txt"
(
  ip() { printf '%s\n' '[{"addr_info":[{"scope":"global","family":"inet","local":"192.0.2.1"},{"scope":"global","family":"inet","local":"192.0.2.2"}]}]'; }
  getent() { printf '192.0.2.2 STREAM\n'; }
  [[ $(dns_check hy-b.example.com 0 true) == 192.0.2.2 ]]
  getent() { printf '192.0.2.1 STREAM\n192.0.2.2 STREAM\n'; }
  if (dns_check hy-b.example.com 0 true) >/dev/null 2>&1; then echo 'accepted two A records for one node'; exit 1; fi
  fetch() { printf 'fl=1\nip=192.0.2.2\nts=1\n'; }
  egress_check 192.0.2.2
  if (egress_check 192.0.2.1) >/dev/null 2>&1; then echo 'accepted wrong egress IP'; exit 1; fi
  ss() { printf 'UNCONN 0 0 192.0.2.1:443 0.0.0.0:* users:(("hysteria",pid=7,fd=3))\n'; }
  port_held_by_hysteria 443
  ss() { printf 'UNCONN 0 0 0.0.0.0:443 0.0.0.0:* users:(("other",pid=8,fd=3))\n'; }
  if port_held_by_hysteria 443; then echo 'treated foreign listener as hysteria'; exit 1; fi
)
if (( BASH_VERSINFO[0] >= 4 )); then
  normalize_domains 'HY.example.com.' 'hy-b.example.com, hy-c.example.com'
  [[ "${domains[*]}" == 'hy.example.com hy-b.example.com hy-c.example.com' ]]
  if (normalize_domains a.example.com A.example.com) >/dev/null 2>&1; then echo 'accepted duplicate domain'; exit 1; fi
fi

if verify_binary "$work/new" "sha256:$(printf '%064d' 0)"; then echo 'wrong checksum accepted'; exit 1; fi
bash hysteria.sh --help > "$work/file-help"
# shellcheck disable=SC2002 # Exercise a real pipe, matching curl | bash.
cat hysteria.sh | bash -s -- --help > "$work/pipe-help"
cmp "$work/file-help" "$work/pipe-help"
bash -s -- --help < hysteria.sh > "$work/stdin-help"
cmp "$work/file-help" "$work/stdin-help"
if bash hysteria.sh upgrade --domain hy.example.com --dry-run >/dev/null 2>&1; then exit 1; fi
if bash hysteria.sh --domain bad --dry-run >/dev/null 2>&1; then exit 1; fi
printf 'PASS configuration preservation, credential escaping, validation, multi-IPv4 nodes and checksum rejection\n'
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

# Multiple IPv4 nodes on one host. Docker NAT hides the real egress, so stub only the egress check.
base=${ip%.*}; ip2=$base.201; ip3=$base.202
ip addr add "$ip2/32" dev eth0; ip addr add "$ip3/32" dev eth0
printf '%s hy2b.integration.test\n%s hy2c.integration.test\n' "$ip2" "$ip3" >> /etc/hosts
for extra in hy2b.integration.test hy2c.integration.test; do
  dir=/var/lib/hysteria/acme/certificates/acme-v02.api.letsencrypt.org-directory/$extra
  mkdir -p "$dir"
  openssl req -x509 -newkey rsa:2048 -nodes -days 90 -subj "/CN=$extra" -addext "subjectAltName=DNS:$extra" -keyout "$dir/$extra.key" -out "$dir/$extra.crt" 2>/dev/null
  printf '{"sans":["%s"],"issuer_data":{}}\n' "$extra" > "$dir/$extra.json"
done
chown -R hysteria:hysteria /var/lib/hysteria
cat > "$scratch/multi.sh" <<'MULTI'
#!/usr/bin/env bash
source /repo/hysteria.sh
egress_check() { printf 'egress check skipped for %s\n' "$1"; }
main "$@"
MULTI
primary_password=$(jq -r .auth.password "$config")
bash "$scratch/multi.sh" --domain "$domain" --domain hy2b.integration.test,hy2c.integration.test --non-interactive > "$scratch/multi.log" 2>&1 || { cat "$scratch/multi.log"; exit 1; }
[[ $(jq -r .auth.password "$config") == "$primary_password" ]]
jq -e --arg ip "$ip" '.listen==($ip+":24443") and .acme.listenHost==$ip and .outbounds[0].direct.bindIPv4==$ip' "$config" >/dev/null
for pair in "hy2b.integration.test $ip2" "hy2c.integration.test $ip3"; do
  read -r extra extra_ip <<< "$pair"
  systemctl is-active --quiet "hysteria-server@$extra"
  systemctl is-enabled --quiet "hysteria-server@$extra"
  [[ $(stat -c '%U:%G:%a' "/etc/hysteria/nodes/$extra.yaml") == root:hysteria:640 ]]
  jq -e --arg ip "$extra_ip" '.listen==($ip+":24443") and .acme.listenHost==$ip and .outbounds[0].direct.bindIPv4==$ip and .outbounds[0].direct.mode=="4"' "/etc/hysteria/nodes/$extra.yaml" >/dev/null
  ss -H -lun "sport = :24443" | grep -Fq "$extra_ip:24443"
done
jq -e '(.proxies|length)==3' /etc/hysteria/client/clash.yaml >/dev/null
[[ $(grep -c '^hysteria2://' /etc/hysteria/client/hy2.txt) == 3 ]]
cert_b=/var/lib/hysteria/acme/certificates/acme-v02.api.letsencrypt.org-directory/hy2b.integration.test/hy2b.integration.test.crt
jq --arg cert "$cert_b" '{server:"hy2b.integration.test:24443",auth:.auth.password,tls:{sni:"hy2b.integration.test",ca:$cert},socks5:{listen:"127.0.0.1:21081"}}' /etc/hysteria/nodes/hy2b.integration.test.yaml > "$scratch/client-b.json"
/usr/local/bin/hysteria client -c "$scratch/client-b.json" > "$scratch/client-b.log" 2>&1 & client_pid=$!
for ((i=0;i<30;i++)); do
 if [[ -n $(ss -Hltn 'sport = :21081') ]]; then break; fi
 sleep .2
done
curl -fsS --max-time 30 --proxy socks5h://127.0.0.1:21081 https://www.gstatic.com/generate_204 >/dev/null
kill "$client_pid"; wait "$client_pid" || true; client_pid=''
printf 'PASS three IPv4 nodes: separate listeners, bound egress, exports and real QUIC through an extra node\n'

bash "$scratch/multi.sh" --domain "$domain" --domain hy2b.integration.test --non-interactive > "$scratch/shrink.log" 2>&1 || { cat "$scratch/shrink.log"; exit 1; }
systemctl is-active --quiet hysteria-server@hy2b.integration.test
if systemctl is-active --quiet hysteria-server@hy2c.integration.test; then echo 'removed node still running'; exit 1; fi
if systemctl is-enabled --quiet hysteria-server@hy2c.integration.test 2>/dev/null; then echo 'removed node still enabled'; exit 1; fi
[[ ! -e /etc/hysteria/nodes/hy2c.integration.test.yaml ]]
jq -e '(.proxies|length)==2' /etc/hysteria/client/clash.yaml >/dev/null
bash hysteria.sh upgrade --non-interactive > "$scratch/upgrade-multi.log" 2>&1 || { cat "$scratch/upgrade-multi.log"; exit 1; }
systemctl is-active --quiet hysteria-server
systemctl is-active --quiet hysteria-server@hy2b.integration.test
printf 'PASS dropping a node stops, disables and removes it; upgrade restarts every node\n'

# A new node that fails after the switch must leave the existing nodes as they were.
cat > "$scratch/multi-fail.sh" <<'MULTI'
#!/usr/bin/env bash
source /repo/hysteria.sh
egress_check() { :; }
eval "real_$(declare -f wait_ready)"
wait_ready() { [[ $1 != hysteria-server@hy2c.integration.test ]] || return 1; real_wait_ready "$@"; }
main "$@"
MULTI
sha256sum "$config" /etc/hysteria/nodes/hy2b.integration.test.yaml /etc/hysteria/client/clash.yaml > "$scratch/multi.sha"
if bash "$scratch/multi-fail.sh" --domain "$domain" --domain hy2b.integration.test,hy2c.integration.test --non-interactive > "$scratch/multi-fail.log" 2>&1; then
  echo 'failed node accepted'; exit 1
fi
grep -q '已恢复部署前文件及服务状态' "$scratch/multi-fail.log" || { cat "$scratch/multi-fail.log"; exit 1; }
sha256sum -c "$scratch/multi.sha"
[[ ! -e /etc/hysteria/nodes/hy2c.integration.test.yaml ]]
if systemctl is-enabled --quiet hysteria-server@hy2c.integration.test 2>/dev/null; then echo 'failed node left enabled'; exit 1; fi
systemctl is-active --quiet hysteria-server
systemctl is-active --quiet hysteria-server@hy2b.integration.test
systemctl is-enabled --quiet hysteria-server@hy2b.integration.test
printf 'PASS failed multi-node switch restores existing nodes, exports and enablement\n'
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
