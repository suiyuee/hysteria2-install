#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG=/etc/hysteria/config.yaml
BINARY=/usr/local/bin/hysteria
UNIT=/etc/systemd/system/hysteria-server.service
# 多 IPv4：第一个域名沿用上面的配置和服务，其余每个域名一个实例。
NODES=/etc/hysteria/nodes
TEMPLATE=/etc/systemd/system/hysteria-server@.service
DATA=/var/lib/hysteria
EXPORT=/etc/hysteria/client
API=https://api.github.com/repos/HyNetworks/hysteria/releases

fail() { printf '部署未完成：%s\n' "$*" >&2; exit 1; }
usage() {
  cat <<'HELP'
用法：bash hysteria.sh [install|upgrade|reconfigure] [参数]
Debian 13.x / systemd，IPv4 接入，自动检测 IPv6 出口。默认安装，已有配置时改为重新配置。
多个域名即多个 IPv4 节点；重新配置时不在列表里的附加节点会被停用并删除配置。
  --domain 域名          直接解析到本机；可重复或用逗号分隔。多个域名时
                         每个域名的 A 记录指向本机一个不同的 IPv4，
                         各自监听并从该 IP 出网
  --port 端口            新安装默认 443
  --v6-port 端口         IPv6 优先节点的 UDP 端口，默认主端口 + 1（65535 时取 65534）
  --email 邮箱           可选，新安装默认不填
  --masquerade-url URL   HTTPS 伪装网页
  --builtin-site         使用内置网页
  --version v2.x.x       安装/升级指定版本，默认最新稳定版
  --dns-wait 秒数|forever 默认一直等待 DNS，每 5 秒检查一次
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
fetch() { curl --ipv4 --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 180 --retry 2 "$@"; }
contains() { local want=$1 item; shift; for item; do [[ $item == "$want" ]] && return 0; done; return 1; }
local_ipv4s() { ip -j addr | jq -r '.[].addr_info[] | select(.scope=="global" and .family=="inet") | .local'; }
# 附加节点：已有 *.yaml 的文件名即域名。
extra_nodes() { local f; for f in "$NODES"/*.yaml; do [[ -e $f ]] && basename "$f" .yaml; done; return 0; }

prepare_config() {
  local old=$1 output=$2 domain=$3 email=$4 port=$5 url=$6 builtin=$7 password
  password=$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')
  jq --arg domain "$domain" --arg email "$email" \
    --arg port "$port" --arg password "$password" --arg url "$url" --arg data "$DATA" --argjson builtin "$builtin" '
    del(.tls) |
    .listen = ("0.0.0.0:" + $port) |
    .outbounds = ((if (.outbounds // [] | length) == 0 then [{name:"direct",type:"direct"}] else .outbounds end) |
      map(if .type == "direct" then .direct.mode = "4" | del(.direct.bindIPv6) else . end)) |
    .auth = {type:"password", password:(.auth.password // $password)} |
    if .acme.domains == [$domain] then
      if $email != "" then .acme.email = $email else . end
    else .acme = {domains:[$domain],ca:"letsencrypt",type:"http",dir:($data+"/acme")} |
      if $email != "" then .acme.email = $email else . end end |
    if $url != "" then .masquerade = {type:"proxy",proxy:{url:$url,rewriteHost:true}}
    elif $builtin or (.masquerade == null) then .masquerade = {type:"file",file:{dir:($data+"/www")}}
    else . end' "$old" > "$output"
}

# 多 IPv4 节点：监听、证书验证和直连出口都绑定这个 IP，各节点互不占用端口。
node_config() {
  local src=$1 output=$2 ip=$3
  jq --arg ip "$ip" '
    .listen = ($ip + ":" + (.listen | split(":") | last)) |
    .acme.listenHost = $ip |
    .outbounds |= map(if .type == "direct" then .direct.bindIPv4 = $ip | del(.direct.bindDevice) else . end)' "$src" > "$output"
}

# A verified TLS response proves direct IPv6 reachability, regardless of HTTP status.
ipv6_egress() {
  local endpoint host addr state=no-route
  for endpoint in 'cloudflare-dns.com 2606:4700:4700::1111' 'dns.google 2001:4860:4860::8888'; do
    read -r host addr <<< "$endpoint"
    ip -6 route get "$addr" >/dev/null 2>&1 || continue
    state=unconfirmed
    if curl -q --ipv6 --noproxy '*' --resolve "$host:443:[$addr]" --silent \
        --output /dev/null --connect-timeout 3 --max-time 5 "https://$host/"; then
      printf 'available\n'; return
    fi
  done
  printf '%s\n' "$state"
}

prepare_v6_config() {
  jq --arg port "$3" '
    .listen |= sub(":[0-9]+$"; ":" + $port) |
    .outbounds |= map(if .type == "direct" then .direct.mode = "64" else . end) |
    del(.masquerade.listenHTTP, .masquerade.listenHTTPS, .trafficStats)
  ' "$1" > "$2"
}

export_client() {
  local dest=$1; shift
  jq -n '
    def node: .acme.domains[0] as $d | (.listen | split(":") | last | tonumber) as $port |
      {name:(if (input_filename | split("/") | last | startswith("_v6-")) then $d+" (IPv6)" else $d end),type:"hysteria2",server:$d,port:$port,"ip-version":"ipv4",password:.auth.password,sni:$d,"skip-cert-verify":false}
      + (if .obfs.type == "salamander" then {obfs:"salamander","obfs-password":.obfs.salamander.password} else {} end);
    [inputs | node] as $nodes |
    {"mixed-port":7890,"allow-lan":false,ipv6:false,dns:{ipv6:false},mode:"rule",proxies:$nodes,
     "proxy-groups":[{name:"代理选择",type:"select",proxies:(($nodes | map(.name)) + ["DIRECT"])}],
     rules:["IP-CIDR,127.0.0.0/8,DIRECT","IP-CIDR,10.0.0.0/8,DIRECT","IP-CIDR,172.16.0.0/12,DIRECT","IP-CIDR,192.168.0.0/16,DIRECT","MATCH,代理选择"]}' "$@" > "$dest/clash.yaml"
  jq -r '.proxies[] |
    "hysteria2://" + (.password|@uri) + "@" + .server + ":" + (.port|tostring) + "/?sni=" + .sni + "&insecure=0" +
    (if .obfs then "&obfs=salamander&obfs-password=" + (.["obfs-password"]|@uri) else "" end) + "#" + (.name|@uri)' "$dest/clash.yaml" > "$dest/hy2.txt"
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

# 域名只解析到本机 IPv4；single=true 时只能有一条 A 记录，并输出该 IP。
dns_check() {
  local domain=$1 wait=$2 end=0 single=${3:-false} local_ips resolved ip good
  if [[ $wait != forever ]]; then end=$((SECONDS + wait)); fi
  local_ips=$(local_ipv4s)
  while :; do
    resolved=$(getent -A ahosts "$domain" | awk '{print $1}' | sort -u) || resolved=''
    good=true
    [[ -n $resolved ]] || good=false
    if [[ $single == true && $(grep -c . <<< "$resolved") != 1 ]]; then good=false; fi
    while IFS= read -r ip; do
      grep -Fxq -- "$ip" <<< "$local_ips" || good=false
    done <<< "$resolved"
    if $good; then
      if [[ $single == true ]]; then printf '%s\n' "$resolved"; fi
      return
    fi
    if [[ $wait != forever ]] && (( SECONDS >= end )); then
      if [[ $single == true ]]; then fail "DNS 未就绪：$domain。多节点时每个域名只能有一条 A 记录，指向本机的一个 IPv4；删除 AAAA 记录并关闭 CDN。"; fi
      fail "DNS 未就绪：$domain。请将 A 记录指向本机 IPv4，删除 AAAA 记录并关闭 CDN。"
    fi
    printf '等待 %s 的 A 记录指向本机 IPv4，5 秒后重试（Ctrl+C 取消）……\n' "$domain" >&2
    sleep 5
  done
}
# 用该 IP 发起一次外网请求，确认出口就是它自己；附加 IP 走了别的出口时需要先配置策略路由。
egress_check() {
  local ip=$1 seen
  seen=$(fetch --interface "$ip" https://1.1.1.1/cdn-cgi/trace | sed -n 's/^ip=//p') || seen=''
  [[ $seen == "$ip" ]] || fail "从 $ip 出网时对外显示为 ${seen:-（请求失败）}。请确认该 IP 已配置在网卡上，必要时为它配置策略路由。"
}
port_free() { [[ -z $(ss -H "-l${1}n" "sport = :$2") ]]; }
# 端口只被本脚本的 hysteria 实例占用时，重新配置可以接管。
port_held_by_hysteria() {
  local lines
  lines=$(ss -H -lunp "sport = :$1")
  [[ -n $lines ]] && ! grep -vq 'users:(("hysteria"' <<< "$lines"
}
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
  local i path tmp name failed=0
  systemctl stop hysteria-server 'hysteria-server@*.service' >/dev/null 2>&1 || failed=1
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
  # 附加节点恢复部署前的开机启动状态。
  for name in "${touched_nodes[@]}"; do
    if contains "$name" "${enabled_nodes[@]}"; then
      ln -sf "$TEMPLATE" "/etc/systemd/system/multi-user.target.wants/hysteria-server@$name.service" || failed=1
    else rm -f "/etc/systemd/system/multi-user.target.wants/hysteria-server@$name.service" || failed=1; fi
  done
  systemctl daemon-reload || failed=1
  systemctl reset-failed hysteria-server 'hysteria-server@*.service' >/dev/null 2>&1 || true
  if [[ $was_active == true ]]; then
    if systemctl restart hysteria-server && wait_ready hysteria-server 30; then :; else failed=1; fi
  fi
  for name in "${active_nodes[@]}"; do
    if systemctl restart "hysteria-server@$name" && wait_ready "hysteria-server@$name" 30; then :; else failed=1; fi
  done
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
# 删除前同样备份，失败时由 rollback 放回。
remove_file() {
  local dest=$1 i=${#targets[@]}
  [[ -e $dest ]] || return 0
  [[ ! -L $dest ]] || fail "不删除符号链接：$dest"
  cp -a -- "$dest" "$backup/$i"
  existed+=(yes)
  targets+=("$dest")
  printf '%s\t%s\t%s\n' "$i" yes "$dest" >> "$backup/files.tsv"
  rm -f -- "$dest"
}

# 域名列表：小写、去掉末尾点、逐个校验且不重复；可用空格或逗号分隔。
normalize_domains() {
  local raw item
  local -a items
  domains=()
  for raw; do
    IFS=', ' read -r -a items <<< "$raw"
    for item in "${items[@]}"; do
      [[ -n $item ]] || continue
      item=${item,,}; item=${item%.}
      valid_domain "$item" || fail "请填写域名，不带协议、路径、端口或 IP：$item"
      ! contains "$item" "${domains[@]}" || fail "域名重复：$item"
      domains+=("$item")
    done
  done
}

main() {
  local action=install email='' port='' url='' version='' builtin=false noninteractive=false dry=false dns_wait=forever
  local v6_port='' old_v6_port='' v6_state src
  local -a v6_domains=() ports=()
  local arg old old_port current_domain missing=() p os_id os_version name ip multi=false
  local -a given=() domains=() old_nodes=() extras=() removed=() node_ips=() configs=()
  if [[ ${1:-} != -* && $# -gt 0 ]]; then action=$1; shift; fi
  case $action in install|upgrade|reconfigure) ;; *) fail '操作只能是 install、upgrade 或 reconfigure。';; esac
  while (( $# )); do
    arg=$1; shift
    case $arg in
      --help|-h) usage; return;;
      --non-interactive) noninteractive=true;; --dry-run) dry=true;; --builtin-site) builtin=true;;
      --domain|--email|--port|--v6-port|--masquerade-url|--version|--dns-wait)
        if (( $# == 0 )) || [[ -z $1 || $1 == --* ]]; then fail "$arg 缺少值。"; fi
        case $arg in --domain) given+=("$1");; --email) email=$1;; --port) port=$1;; --v6-port) v6_port=$1;; --masquerade-url) url=$1;; --version) version=$1;; --dns-wait) dns_wait=$1;; esac
        shift;;
      *) fail "未知参数：$arg";;
    esac
  done
  [[ $builtin == false || -z $url ]] || fail '不能同时指定两种伪装网页。'
  [[ $action != upgrade || ( ${#given[@]} == 0 && -z $email$port$v6_port$url && $builtin == false ) ]] || fail 'upgrade 只升级核心。'
  [[ $action != reconfigure || -z $version ]] || fail 'reconfigure 不升级核心。'
  [[ -z $version || $version =~ ^(app/)?v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail '版本格式应为 v2.x.x。'
  if [[ $dns_wait != forever ]]; then
    number "$dns_wait" || fail 'DNS 等待时间应为秒数或 forever。'
    dns_wait=$((10#$dns_wait))
  fi
  if [[ -n $port ]]; then if ! number "$port" || ((10#$port < 1 || 10#$port > 65535)); then fail '端口必须为 1–65535。'; fi; port=$((10#$port)); fi
  [[ -z $email || $email =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || fail '邮箱格式错误。'
  [[ -z $url || $url =~ ^https://[a-zA-Z0-9.-]+(:[0-9]+)?([/?#][^[:space:]]*)?$ ]] || fail '伪装网页必须为 HTTPS 地址。'
  if (( ${#given[@]} )); then normalize_domains "${given[@]}"; fi

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
  while IFS= read -r name; do [[ -z $name ]] || old_nodes+=("$name"); done < <(extra_nodes)
  if [[ $action != upgrade ]]; then
    if [[ $old != '{}' ]]; then
      jq -e '.auth.type=="password" and (.auth.password|type=="string" and length>0) and
        ((.obfs==null) or (.obfs.type=="salamander" and (.obfs.salamander.password|type=="string" and length>0)))' <<< "$old" >/dev/null || fail '现有认证或混淆设置不受支持。'
    fi
    current_domain=$(jq -r '.acme.domains[0] // ""' <<< "$old")
    if (( ${#domains[@]} == 0 )); then
      arg="$current_domain"
      for name in "${old_nodes[@]}"; do [[ $name == _v6-* ]] || arg+=" $name"; done
      if [[ $noninteractive == false ]]; then
        printf '连接域名，多个 IPv4 节点用空格分隔 [%s]: ' "$arg" > /dev/tty
        read -r p < /dev/tty || fail '无法读取域名，请用 --domain。'
        arg=${p:-$arg}
      fi
      normalize_domains "$arg"
    fi
    (( ${#domains[@]} )) || fail '需要正确的连接域名。'
    extras=("${domains[@]:1}")
    (( ${#extras[@]} == 0 )) || multi=true
    if command -v ip >/dev/null; then v6_state=$(ipv6_egress); else v6_state=unconfirmed; fi
    case $v6_state in
      no-route) printf '没有公网 IPv6 路由，仅配置 IPv4 节点。\n';;
      unconfirmed) printf '未确认 IPv6 出口，仅保留所选域名已有的 IPv6 节点。\n';;
    esac
    for name in "${domains[@]}"; do
      if [[ $v6_state == available ]] || { [[ $v6_state == unconfirmed ]] && contains "_v6-$name" "${old_nodes[@]}"; }; then
        v6_domains+=("$name")
        extras+=("_v6-$name")
      fi
    done
    for name in "${old_nodes[@]}"; do contains "$name" "${extras[@]}" || removed+=("$name"); done
    old_port=$(jq -r '.listen // ":443"' <<< "$old")
    [[ $old_port =~ :[0-9]+$ ]] || fail '现有监听方式不受支持。'
    port=${port:-${old_port##*:}}
    if ! number "$port" || ((10#$port < 1 || 10#$port > 65535)); then fail '端口必须为 1–65535。'; fi
    port=$((10#$port))
    ports=("$port")
    printf 'IPv4 节点 UDP %s。\n' "$port"
    if (( ${#v6_domains[@]} )); then
      if [[ -f $NODES/_v6-$current_domain.yaml && $port == "${old_port##*:}" ]]; then
        old_v6_port=$(jq -r '.listen|split(":")|last' "$NODES/_v6-$current_domain.yaml")
      fi
      v6_port=${v6_port:-${old_v6_port:-$((port == 65535 ? port - 1 : port + 1))}}
      if ! number "$v6_port" || ((10#$v6_port < 1 || 10#$v6_port > 65535 || 10#$v6_port == port)); then
        fail 'IPv6 优先节点需要不同的有效 UDP 端口。'
      fi
      v6_port=$((10#$v6_port))
      ports+=("$v6_port")
      printf 'IPv6 优先节点 UDP %s。\n' "$v6_port"
    fi
  else extras=("${old_nodes[@]}"); fi
  printf '操作：%s；%s\n' "$action" "${domains[*]:-保留已有配置}"
  if (( ${#removed[@]} )); then printf '将停用附加节点：%s\n' "${removed[*]}"; fi
  if [[ $dry == true ]]; then printf '检查通过，未修改系统。\n'; return; fi

  umask 077
  transaction=false stage='' work='' backup='' had_unit=false was_active=false
  targets=() existed=() pending=() touched_nodes=() enabled_nodes=() active_nodes=()
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  id hysteria >/dev/null 2>&1 || useradd --system --user-group --home-dir "$DATA" --shell /usr/sbin/nologin hysteria
  install -d -o hysteria -g hysteria -m 700 "$DATA" "$DATA/acme"
  work=$(mktemp -d "$DATA/.install-XXXXXXXX")
  chown hysteria:hysteria "$work"
  install -d -o hysteria -g hysteria -m 700 "$work/nodes"
  printf '%s\n' "$old" > "$work/old.json"
  if [[ $action == upgrade ]]; then
    cp "$CONFIG" "$work/config.json"
    for name in "${extras[@]}"; do cp "$NODES/$name.yaml" "$work/nodes/$name.json"; done
  else
    prepare_config "$work/old.json" "$work/config.json" "${domains[0]}" "$email" "$port" "$url" "$builtin"
    for name in "${domains[@]:1}"; do
      if [[ -e $NODES/$name.yaml ]]; then cp "$NODES/$name.yaml" "$work/nodes/$name.old"; else printf '{}\n' > "$work/nodes/$name.old"; fi
      prepare_config "$work/nodes/$name.old" "$work/nodes/$name.json" "$name" "$email" "$port" "$url" "$builtin"
    done
    if [[ $multi == true ]]; then
      for name in "${domains[@]}"; do
        ip=$(dns_check "$name" "$dns_wait" true)
        ! contains "$ip" "${node_ips[@]}" || fail "多个域名解析到同一个 IP：$ip。每个节点需要不同的 IPv4。"
        node_ips+=("$ip")
        egress_check "$ip"
        printf '%s → %s，出口确认\n' "$name" "$ip"
      done
      node_config "$work/config.json" "$work/config.ip" "${node_ips[0]}"
      mv "$work/config.ip" "$work/config.json"
      for ((p=1; p<${#domains[@]}; p++)); do
        node_config "$work/nodes/${domains[p]}.json" "$work/nodes/${domains[p]}.ip" "${node_ips[p]}"
        mv "$work/nodes/${domains[p]}.ip" "$work/nodes/${domains[p]}.json"
      done
    else dns_check "${domains[0]}" "$dns_wait"; fi
    if [[ $(jq -r '.acme.type // "http"' "$work/config.json") == http ]]; then port_free t 80 || fail 'TCP 80 已占用。'; fi
    for p in "${ports[@]}"; do
      if ! port_free u "$p" && ! port_held_by_hysteria "$p"; then fail "UDP $p 已被其它程序占用。"; fi
    done
    for name in "${v6_domains[@]}"; do
      src="$work/nodes/$name.json"
      if [[ $name == "${domains[0]}" ]]; then src="$work/config.json"; fi
      prepare_v6_config "$src" "$work/nodes/_v6-$name.json" "$v6_port"
    done
  fi
  configs=("$work/config.json")
  for name in "${extras[@]}"; do configs+=("$work/nodes/$name.json"); done
  if [[ $action == reconfigure ]]; then cp "$BINARY" "$work/hysteria"; chmod 755 "$work/hysteria"
  else download_binary "$work/hysteria" "$version"; fi
  for p in "${configs[@]}"; do
    jq '.listen="0.0.0.0:0" | .masquerade={type:"string",string:{content:"setup"}}' "$p" > "$work/preview.json"
    chown hysteria:hysteria "$work/preview.json"
    stage="hy2-setup-${work##*/}"
    systemd-run --quiet --unit="$stage" --property=User=hysteria --property=Group=hysteria \
      --property=AmbientCapabilities=CAP_NET_BIND_SERVICE "$work/hysteria" server -c "$work/preview.json"
    wait_ready "$stage" 240
    systemctl stop "$stage"
    systemctl reset-failed "$stage" >/dev/null 2>&1 || true
  done
  stage=''
  if [[ $action != upgrade ]]; then
    export_client "$work" "${configs[@]}"
    write_site > "$work/index.html"
    write_service > "$work/service"
    write_template > "$work/template"
  fi
  backup=$(mktemp -d /root/hy2-backup-XXXXXXXX)
  [[ ! -f $UNIT ]] || had_unit=true
  if systemctl is-active --quiet hysteria-server; then was_active=true; fi
  touched_nodes=("${old_nodes[@]}")
  for name in "${extras[@]}"; do contains "$name" "${touched_nodes[@]}" || touched_nodes+=("$name"); done
  for name in "${old_nodes[@]}"; do
    if systemctl is-enabled --quiet "hysteria-server@$name" 2>/dev/null; then enabled_nodes+=("$name"); fi
    if systemctl is-active --quiet "hysteria-server@$name"; then active_nodes+=("$name"); fi
  done
  printf 'active=%s\nunit_existed=%s\nactive_nodes=%s\n' "$was_active" "$had_unit" "${active_nodes[*]}" > "$backup/state"
  transaction=true
  if [[ $action != reconfigure ]]; then replace_file "$work/hysteria" "$BINARY" 755; fi
  if [[ $action != upgrade ]]; then
    install -d -o root -g hysteria -m 750 /etc/hysteria
    install -d -o root -g root -m 700 "$EXPORT"
    replace_file "$work/config.json" "$CONFIG" 640 hysteria
    if [[ $had_unit == false ]]; then replace_file "$work/service" "$UNIT" 644; fi
    if (( ${#extras[@]} )); then
      install -d -o root -g hysteria -m 750 "$NODES"
      if [[ ! -f $TEMPLATE ]]; then replace_file "$work/template" "$TEMPLATE" 644; fi
    fi
    for name in "${extras[@]}"; do replace_file "$work/nodes/$name.json" "$NODES/$name.yaml" 640 hysteria; done
    for name in "${removed[@]}"; do remove_file "$NODES/$name.yaml"; done
    if [[ $(jq -r '.masquerade.file.dir // ""' "$work/config.json") == "$DATA/www" && ! -e $DATA/www/index.html ]]; then
      replace_file "$work/index.html" "$DATA/www/index.html" 644
      chmod 755 "$DATA/www"
    fi
    replace_file "$work/clash.yaml" "$EXPORT/clash.yaml" 600
    replace_file "$work/hy2.txt" "$EXPORT/hy2.txt" 600
  fi
  systemctl daemon-reload
  # 先停掉附加节点，主节点从 0.0.0.0 改为绑定单个 IP 后再逐个启动，避免端口冲突。
  for name in "${old_nodes[@]}"; do systemctl stop "hysteria-server@$name"; done
  for name in "${removed[@]}"; do
    systemctl disable --quiet "hysteria-server@$name" 2>/dev/null || rm -f "/etc/systemd/system/multi-user.target.wants/hysteria-server@$name.service"
  done
  systemctl reset-failed hysteria-server 2>/dev/null || true
  systemctl restart hysteria-server
  wait_ready hysteria-server 30
  for name in "${extras[@]}"; do
    systemctl reset-failed "hysteria-server@$name" 2>/dev/null || true
    systemctl restart "hysteria-server@$name"
    wait_ready "hysteria-server@$name" 30
  done
  if [[ $had_unit == false ]]; then systemctl enable hysteria-server; fi
  for name in "${extras[@]}"; do systemctl enable --quiet "hysteria-server@$name"; done
  transaction=false
  printf '部署完成。备份：%s\n' "$backup"
  if [[ $action != upgrade ]]; then
    printf 'Clash 配置：%s/clash.yaml\n节点链接：%s/hy2.txt\n' "$EXPORT" "$EXPORT"
    cat "$EXPORT/hy2.txt"
  fi
}

write_site() {
  cat <<'HY2_ASSET'
<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>松间 · 把日子过得慢一点</title><style>body{margin:0;background:#f5f3eb;color:#293e35;font:18px/1.9 system-ui}main{max-width:720px;margin:auto;padding:14vh 24px}small{letter-spacing:.2em}h1{font-size:clamp(36px,7vw,64px);line-height:1.2}article{margin:64px 0;border-top:1px solid #ccd2c8;padding-top:24px}footer{color:#69786c}</style><main><small>BETWEEN THE PINES · 松间</small><h1>把日子过得慢一点。</h1><p>记下一次散步、一本书，还有清晨的一束光。</p><article><h2>去树下走走</h2><p>不设目的地，沿着树荫慢慢走。风吹过叶子，细碎的声音让人重新留意身边的日常。</p></article><article><h2>留一点时间给阅读</h2><p>关掉提醒，翻开读到一半的书。不必急着读完，今天记住一句喜欢的话就很好。</p></article><footer>松间 · 日常记录</footer></main></html>
HY2_ASSET
}

write_service() {
  cat <<'HY2_ASSET'
[Unit]
Description=Hysteria 2 Server
After=network-online.target
Wants=network-online.target
[Service]
User=hysteria
Group=hysteria
WorkingDirectory=/var/lib/hysteria
ExecStart=/usr/local/bin/hysteria server --config /etc/hysteria/config.yaml
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=/var/lib/hysteria
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target

HY2_ASSET
}

write_template() {
  cat <<'HY2_ASSET'
[Unit]
Description=Hysteria 2 Server (%i)
After=network-online.target
Wants=network-online.target
[Service]
User=hysteria
Group=hysteria
WorkingDirectory=/var/lib/hysteria
ExecStart=/usr/local/bin/hysteria server --config /etc/hysteria/nodes/%i.yaml
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=/var/lib/hysteria
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target

HY2_ASSET
}

if [[ ${BASH_SOURCE[0]:-"$0"} == "$0" ]]; then main "$@"; fi
