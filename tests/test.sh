#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source dist/hysteria.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
for domain in example.com hy.example.com; do valid_domain "$domain"; done
for domain in '-a.example.com' 'a..example.com' '127.0.0.1' 'https://example.com' 'x.com:443'; do
  if valid_domain "$domain"; then echo "accepted invalid domain: $domain"; exit 1; fi
done
printf '{}\n' > "$work/old"
prepare_config "$work/old" "$work/new" hy.example.com '' 443 '' false
jq -e '.auth.password|length==64' "$work/new" >/dev/null
jq -e '.acme.email=="1094620146@qq.com"' "$work/new" >/dev/null
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
bash dist/hysteria.sh --help >/dev/null
if bash dist/hysteria.sh upgrade --domain hy.example.com --dry-run >/dev/null 2>&1; then exit 1; fi
if bash dist/hysteria.sh --domain bad --dry-run >/dev/null 2>&1; then exit 1; fi
printf 'PASS configuration preservation, credential escaping, validation and checksum rejection\n'
