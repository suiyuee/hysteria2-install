#!/usr/bin/env bash
# Only for the disposable Debian 13 systemd container created by run-linux.sh.
set -Eeuo pipefail
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
bash dist/hysteria.sh --domain "$domain" --port 24443 --non-interactive > "$scratch/install.log" 2>&1 || { cat "$scratch/install.log"; exit 1; }
if command -v python3; then echo "Unexpected Python runtime"; exit 1; fi
[[ $(stat -c '%U:%G:%a' /etc/hysteria/config.yaml) == root:hysteria:640 ]]
[[ $(stat -c %a /etc/hysteria/client/clash.yaml) == 600 ]]
jq -e '.proxies[0]["skip-cert-verify"]==false' /etc/hysteria/client/clash.yaml >/dev/null
printf 'PASS fresh install on Debian 13 without Python; permissions and exports\n'
bash tests/test.sh
LANG=C.UTF-8 shellcheck -x src/installer.sh scripts/build.sh install.sh tests/*.sh

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
bash dist/hysteria.sh --non-interactive > "$scratch/reconfigure.log" 2>&1 || { cat "$scratch/reconfigure.log"; exit 1; }
sha256sum -c "$scratch/cert.sha" "$scratch/binary.sha"
for field in auth listen masquerade quic acme; do
 [[ $(jq -c ".$field" "$config") == "$(jq -c ".$field" "$scratch/before")" ]]
done
sha256sum "$config" /etc/hysteria/client/clash.yaml /etc/systemd/system/hysteria-server.service > "$scratch/state.sha"
bash dist/hysteria.sh upgrade --non-interactive > "$scratch/upgrade.log" 2>&1 || { cat "$scratch/upgrade.log"; exit 1; }
sha256sum -c "$scratch/state.sha"
printf 'PASS repeat deployment preserves settings/certificate; upgrade leaves config untouched\n'

# Inject a failed formal switch and exercise the exact production EXIT rollback.
cat > "$scratch/rollback.sh" <<'ROLLBACK'
#!/usr/bin/env bash
source /repo/dist/hysteria.sh
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
