#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG=/etc/hysteria/config.yaml
BINARY=/usr/local/bin/hysteria
UNIT=/etc/systemd/system/hysteria-server.service
DATA=/var/lib/hysteria
EXPORT=/etc/hysteria/client
API=https://api.github.com/repos/HyNetworks/hysteria/releases
DEFAULT_EMAIL=1094620146@qq.com

fail() { printf '部署未完成：%s\n' "$*" >&2; exit 1; }
usage() {
  cat <<'HELP'
用法：bash hysteria.sh [install|upgrade|reconfigure] [参数]
Debian 13.x / systemd。默认安装，已有配置时改为重新配置。
  --domain 域名          直接解析到本机
  --port 端口            新安装默认 443
  --email 邮箱           默认 1094620146@qq.com
  --masquerade-url URL   HTTPS 伪装网页
  --builtin-site         使用内置网页
  --version v2.x.x       安装/升级指定版本，默认最新稳定版
  --dns-wait 秒数        默认 180
  --non-interactive      不提问
  --dry-run              只检查输入和计划，不改系统（需要已有 jq）
  --help                 显示帮助
HELP
}

valid_domain() {
  local part
  [[ ${#1} -le 253 && $1 == *.* && $1 != *. && ! $1 =~ ^[0-9.]+$ ]] || return 1
  local -a parts
  IFS=. read -r -a parts <<< "$1"
  for part in "${parts[@]}"; do
    [[ $part =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || return 1
  done
}
number() { [[ $1 =~ ^[0-9]{1,5}$ ]]; }
fetch() { curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 180 --retry 2 "$@"; }

prepare_config() {
  local old=$1 output=$2 domain=$3 email=$4 port=$5 url=$6 builtin=$7 password
  password=$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')
  jq --arg domain "$domain" --arg email "$email" --arg default_email "$DEFAULT_EMAIL" \
    --arg port "$port" --arg password "$password" --arg url "$url" --arg data "$DATA" --argjson builtin "$builtin" '
    del(.tls) |
    .listen = ((.listen // ":443" | sub(":[0-9]+$"; "")) + ":" + $port) |
    .auth = {type:"password", password:(.auth.password // $password)} |
    if .acme.domains == [$domain] then
      if $email != "" then .acme.email = $email else . end
    else .acme = {domains:[$domain],email:(if $email == "" then $default_email else $email end),
                  ca:"letsencrypt",type:"http",dir:($data+"/acme")} end |
    if $url != "" then .masquerade = {type:"proxy",proxy:{url:$url,rewriteHost:true}}
    elif $builtin or (.masquerade == null) then .masquerade = {type:"file",file:{dir:($data+"/www")}}
    else . end' "$old" > "$output"
}

export_client() {
  local config=$1 dest=$2
  jq '
    .acme.domains[0] as $d | (.listen | split(":") | last | tonumber) as $port |
    ({name:$d,type:"hysteria2",server:$d,port:$port,password:.auth.password,sni:$d,"skip-cert-verify":false}
      + (if .obfs.type == "salamander" then {obfs:"salamander","obfs-password":.obfs.salamander.password} else {} end)) as $node |
    {"mixed-port":7890,"allow-lan":false,mode:"rule",proxies:[$node],
     "proxy-groups":[{name:"代理选择",type:"select",proxies:[$d,"DIRECT"]}],
     rules:["IP-CIDR,127.0.0.0/8,DIRECT","IP-CIDR,10.0.0.0/8,DIRECT","IP-CIDR,172.16.0.0/12,DIRECT","IP-CIDR,192.168.0.0/16,DIRECT","MATCH,代理选择"]}' "$config" > "$dest/clash.yaml"
  jq -r '.acme.domains[0] as $d |
    "hysteria2://" + (.auth.password|@uri) + "@" + $d + ":" + (.listen|split(":")|last) + "/?sni=" + $d + "&insecure=0" +
    (if .obfs.type == "salamander" then "&obfs=salamander&obfs-password=" + (.obfs.salamander.password|@uri) else "" end) + "#" + $d' "$config" > "$dest/hy2.txt"
}

verify_binary() {
  local file=$1 digest=$2
  [[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || return 1
  [[ $(sha256sum "$file" | cut -d ' ' -f1) == "${digest#sha256:}" ]]
}
download_binary() {
  local dest=$1 version=$2 arch asset url digest endpoint=latest
  case $(uname -m) in x86_64) arch=amd64;; aarch64) arch=arm64;; *) fail '仅支持 x86_64 / ARM64。';; esac
  if [[ -n $version ]]; then endpoint="tags/app%2F${version#app/}"; fi
  fetch "$API/$endpoint" -o "$work/release.json"
  asset=$(jq -ce --arg name "hysteria-linux-$arch" '.assets[] | select(.name == $name)' "$work/release.json")
  url=$(jq -er '.browser_download_url' <<< "$asset")
  digest=$(jq -er '.digest' <<< "$asset")
  [[ $url == https://github.com/HyNetworks/hysteria/releases/download/* || $url == https://github.com/apernet/hysteria/releases/download/* ]] || fail '发行包地址异常。'
  [[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || fail '官方发行包缺少 SHA256。'
  fetch "$url" -o "$dest"
  verify_binary "$dest" "$digest" || fail '官方核心 SHA256 校验失败。'
  chmod 755 "$dest"
  printf '官方核心 %s 校验通过。\n' "$(jq -r '.tag_name' "$work/release.json")"
}

dns_check() {
  local domain=$1 end=$((SECONDS + $2)) local_ips resolved ip good
  local_ips=$(ip -j addr | jq -r '.[].addr_info[] | select(.scope=="global") | .local')
  while :; do
    resolved=$(getent -A ahosts "$domain" | awk '{print $1}' | sort -u) || resolved=''
    good=true
    [[ -n $resolved ]] || good=false
    while IFS= read -r ip; do
      grep -Fxq -- "$ip" <<< "$local_ips" || good=false
    done <<< "$resolved"
    if $good; then return; fi
    (( SECONDS < end )) || fail "DNS 未就绪：$domain。请检查所有 A/AAAA 记录并关闭 CDN。"
    printf '等待 DNS 生效……\n'
    sleep 5
  done
}
port_free() { [[ -z $(ss -H "-l${1}n" "sport = :$2") ]]; }
wait_ready() {
  local unit=$1 end=$((SECONDS + $2)) status pid state restarts stable=0 sockets
  while (( SECONDS < end )); do
    status=$(systemctl show "$unit" -p ActiveState -p MainPID -p NRestarts)
    state=$(sed -n 's/^ActiveState=//p' <<< "$status")
    pid=$(sed -n 's/^MainPID=//p' <<< "$status")
    restarts=$(sed -n 's/^NRestarts=//p' <<< "$status")
    [[ $state != failed && $state != inactive && ${restarts:-0} == 0 ]] || break
    sockets=$(ss -H -lunp)
    if [[ ${pid:-0} != 0 && $sockets == *"pid=$pid,"* ]]; then
      stable=$((stable + 1))
      if (( stable >= 3 )); then return 0; fi
    else stable=0; fi
    sleep 1
  done
  printf '服务未就绪，请查看：journalctl -u %s\n' "$unit" >&2
  return 1
}

rollback() {
  local i path tmp failed=0
  systemctl stop hysteria-server >/dev/null 2>&1 || failed=1
  for ((i=${#targets[@]}-1; i>=0; i--)); do
    path=${targets[i]}
    if [[ ${existed[i]} == yes ]]; then
      tmp=$(mktemp "${path}.restore.XXXXXX") || { failed=1; continue; }
      if cp -a -- "$backup/$i" "$tmp" && mv -f -- "$tmp" "$path"; then :; else failed=1; rm -f -- "$tmp"; fi
    else rm -f -- "$path" || failed=1; fi
  done
  if [[ $had_unit == false ]]; then
    systemctl disable hysteria-server >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/multi-user.target.wants/hysteria-server.service || failed=1
  fi
  systemctl daemon-reload || failed=1
  systemctl reset-failed hysteria-server >/dev/null 2>&1 || true
  if [[ $was_active == true ]]; then
    if systemctl restart hysteria-server && wait_ready hysteria-server 30; then :; else failed=1; fi
  fi
  if (( failed )); then printf '恢复未完全成功，请检查服务；备份：%s\n' "$backup" >&2
  else printf '已恢复部署前文件及服务状态；备份：%s\n' "$backup" >&2; fi
}
cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  set +e
  if [[ -n ${stage:-} ]]; then systemctl stop "$stage" >/dev/null 2>&1; fi
  if [[ ${transaction:-false} == true ]]; then rollback; fi
  local tmp
  for tmp in "${pending[@]}"; do rm -f -- "$tmp"; done
  if [[ -n ${work:-} ]]; then rm -rf -- "$work"; fi
  if (( rc != 0 )); then printf '部署未完成（退出码 %s）。\n' "$rc" >&2; fi
  exit "$rc"
}
replace_file() {
  local src=$1 dest=$2 mode=$3 group=${4:-root} i=${#targets[@]} tmp
  [[ ! -L $dest ]] || fail "不替换符号链接：$dest"
  mkdir -p -- "$(dirname "$dest")"
  if [[ -e $dest ]]; then
    cp -a -- "$dest" "$backup/$i"
    existed+=(yes)
  else existed+=(no); fi
  targets+=("$dest")
  printf '%s\t%s\t%s\n' "$i" "${existed[i]}" "$dest" >> "$backup/files.tsv"
  tmp=$(mktemp "${dest}.new.XXXXXX")
  # Record temporary paths so failed install/mv does not leave credentials behind.
  pending+=("$tmp")
  install -o root -g "$group" -m "$mode" -- "$src" "$tmp"
  mv -f -- "$tmp" "$dest"
}

main() {
  local action=install domain='' email='' port='' url='' version='' builtin=false noninteractive=false dry=false dns_wait=180
  local arg old old_port current_domain missing=() p os_id os_version
  if [[ ${1:-} != -* && $# -gt 0 ]]; then action=$1; shift; fi
  case $action in install|upgrade|reconfigure) ;; *) fail '操作只能是 install、upgrade 或 reconfigure。';; esac
  while (( $# )); do
    arg=$1; shift
    case $arg in
      --help|-h) usage; return;;
      --non-interactive) noninteractive=true;; --dry-run) dry=true;; --builtin-site) builtin=true;;
      --domain|--email|--port|--masquerade-url|--version|--dns-wait)
        if (( $# == 0 )) || [[ -z $1 || $1 == --* ]]; then fail "$arg 缺少值。"; fi
        case $arg in --domain) domain=$1;; --email) email=$1;; --port) port=$1;; --masquerade-url) url=$1;; --version) version=$1;; --dns-wait) dns_wait=$1;; esac
        shift;;
      *) fail "未知参数：$arg";;
    esac
  done
  [[ $builtin == false || -z $url ]] || fail '不能同时指定两种伪装网页。'
  [[ $action != upgrade || ( -z $domain$email$port$url && $builtin == false ) ]] || fail 'upgrade 只升级核心。'
  [[ $action != reconfigure || -z $version ]] || fail 'reconfigure 不升级核心。'
  [[ -z $version || $version =~ ^(app/)?v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail '版本格式应为 v2.x.x。'
  number "$dns_wait" || fail 'DNS 等待秒数格式不正确。'
  dns_wait=$((10#$dns_wait))
  if [[ -n $port ]]; then if ! number "$port" || ((10#$port < 1 || 10#$port > 65535)); then fail '端口必须为 1–65535。'; fi; port=$((10#$port)); fi
  [[ -z $email || $email =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || fail '邮箱格式错误。'
  [[ -z $url || $url =~ ^https://[a-zA-Z0-9.-]+(:[0-9]+)?([/?#][^[:space:]]*)?$ ]] || fail '伪装网页必须为 HTTPS 地址。'
  if [[ -n $domain ]]; then domain=${domain,,}; domain=${domain%.}; valid_domain "$domain" || fail '请填写域名，不带协议、路径、端口或 IP。'; fi

  if [[ $dry == false ]]; then
    [[ $EUID == 0 && $(uname -s) == Linux ]] || fail '请在 Debian 13.x 上使用 root 运行。'
    os_id=$(. /etc/os-release; printf '%s' "$ID")
    os_version=$(. /etc/os-release; printf '%s' "$VERSION_ID")
    [[ $os_id == debian && ${os_version%%.*} == 13 ]] || fail '此脚本仅适配 Debian 13.x。'
    [[ -d /run/systemd/system ]] || fail '需要 systemd。'
    exec 9>/run/hy2-install.lock
    flock -n 9 || fail '已有安装进程运行。'
    for p in curl jq ca-certificates iproute2; do
      [[ $(dpkg-query -W -f='${Status}' "$p" 2>/dev/null || true) == 'install ok installed' ]] || missing+=("$p")
    done
    if (( ${#missing[@]} )); then
      apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}"
    fi
  fi
  command -v jq >/dev/null || fail '检查配置需要 jq；dry-run 不会自动安装。'
  old='{}'
  if [[ -e $CONFIG ]]; then
    jq -e 'type=="object" and length>0' "$CONFIG" >/dev/null || fail '现有配置不是本脚本生成的 JSON，已停止以免覆盖。'
    old=$(cat "$CONFIG")
    if [[ $action == install ]]; then action=reconfigure; [[ -z $version ]] || fail '已有安装，请使用 upgrade --version。'; fi
  fi
  if [[ $action != install ]]; then
    [[ -s $CONFIG && -x $BINARY && -f $UNIT ]] || fail '未找到完整安装。'
  fi
  if [[ $action != upgrade ]]; then
    if [[ $old != '{}' ]]; then
      jq -e '.auth.type=="password" and (.auth.password|type=="string" and length>0) and
        ((.obfs==null) or (.obfs.type=="salamander" and (.obfs.salamander.password|type=="string" and length>0)))' <<< "$old" >/dev/null || fail '现有认证或混淆设置不受支持。'
    fi
    current_domain=$(jq -r '.acme.domains[0] // ""' <<< "$old")
    if [[ -z $domain ]]; then
      domain=$current_domain
      if [[ $noninteractive == false ]]; then
        printf '连接域名 [%s]: ' "$domain" > /dev/tty
        read -r arg < /dev/tty || fail '无法读取域名，请用 --domain。'
        domain=${arg:-$domain}
      fi
    fi
    domain=${domain,,}; domain=${domain%.}
    valid_domain "$domain" || fail '需要正确的连接域名。'
    old_port=$(jq -r '.listen // ":443"' <<< "$old")
    [[ $old_port =~ :[0-9]+$ ]] || fail '现有监听方式不受支持。'
    port=${port:-${old_port##*:}}
    if ! number "$port" || ((10#$port < 1 || 10#$port > 65535)); then fail '端口必须为 1–65535。'; fi
    port=$((10#$port))
  fi
  printf '操作：%s；%s\n' "$action" "${domain:-保留已有配置}"
  if [[ $dry == true ]]; then printf '检查通过，未修改系统。\n'; return; fi

  umask 077
  transaction=false stage='' work='' backup='' had_unit=false was_active=false
  targets=() existed=() pending=()
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  id hysteria >/dev/null 2>&1 || useradd --system --user-group --home-dir "$DATA" --shell /usr/sbin/nologin hysteria
  install -d -o hysteria -g hysteria -m 700 "$DATA" "$DATA/acme"
  work=$(mktemp -d "$DATA/.install-XXXXXXXX")
  chown hysteria:hysteria "$work"
  printf '%s\n' "$old" > "$work/old.json"
  if [[ $action == upgrade ]]; then cp "$CONFIG" "$work/config.json"
  else
    prepare_config "$work/old.json" "$work/config.json" "$domain" "$email" "$port" "$url" "$builtin"
    dns_check "$domain" "$dns_wait"
    if [[ $(jq -r '.acme.type // "http"' "$work/config.json") == http ]]; then port_free t 80 || fail 'TCP 80 已占用。'; fi
    if ! port_free u "$port"; then
      if [[ ${old_port##*:} != "$port" ]] || ! systemctl is-active --quiet hysteria-server; then fail "UDP $port 已占用。"; fi
    fi
  fi
  if [[ $action == reconfigure ]]; then cp "$BINARY" "$work/hysteria"; chmod 755 "$work/hysteria"
  else download_binary "$work/hysteria" "$version"; fi
  jq '.listen=":0" | .masquerade={type:"string",string:{content:"setup"}}' "$work/config.json" > "$work/preview.json"
  chown hysteria:hysteria "$work/preview.json"
  stage="hy2-setup-${work##*/}"
  systemd-run --quiet --unit="$stage" --property=User=hysteria --property=Group=hysteria \
    --property=AmbientCapabilities=CAP_NET_BIND_SERVICE "$work/hysteria" server -c "$work/preview.json"
  wait_ready "$stage" 240
  systemctl stop "$stage"
  if [[ $action != upgrade ]]; then
    export_client "$work/config.json" "$work"
    write_site > "$work/index.html"
    write_service > "$work/service"
  fi
  backup=$(mktemp -d /root/hy2-backup-XXXXXXXX)
  [[ ! -f $UNIT ]] || had_unit=true
  if systemctl is-active --quiet hysteria-server; then was_active=true; fi
  printf 'active=%s\nunit_existed=%s\n' "$was_active" "$had_unit" > "$backup/state"
  transaction=true
  if [[ $action != reconfigure ]]; then replace_file "$work/hysteria" "$BINARY" 755; fi
  if [[ $action != upgrade ]]; then
    install -d -o root -g hysteria -m 750 /etc/hysteria
    install -d -o root -g root -m 700 "$EXPORT"
    replace_file "$work/config.json" "$CONFIG" 640 hysteria
    if [[ $had_unit == false ]]; then replace_file "$work/service" "$UNIT" 644; fi
    if [[ $(jq -r '.masquerade.file.dir // ""' "$work/config.json") == "$DATA/www" && ! -e $DATA/www/index.html ]]; then
      replace_file "$work/index.html" "$DATA/www/index.html" 644
      chmod 755 "$DATA/www"
    fi
    replace_file "$work/clash.yaml" "$EXPORT/clash.yaml" 600
    replace_file "$work/hy2.txt" "$EXPORT/hy2.txt" 600
  fi
  systemctl daemon-reload
  systemctl reset-failed hysteria-server 2>/dev/null || true
  systemctl restart hysteria-server
  wait_ready hysteria-server 30
  if [[ $had_unit == false ]]; then systemctl enable hysteria-server; fi
  transaction=false
  printf '部署完成。备份：%s\n' "$backup"
  if [[ $action != upgrade ]]; then
    printf 'Clash 配置：%s/clash.yaml\n节点链接：%s/hy2.txt\n' "$EXPORT" "$EXPORT"
    cat "$EXPORT/hy2.txt"
  fi
}
