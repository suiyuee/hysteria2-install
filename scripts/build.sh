#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
cat src/installer.sh > "$tmp"
for item in 'write_site:index.html' 'write_service:hysteria-server.service'; do
  fn=${item%%:*}; asset=${item#*:}
  {
  printf '\n%s() {\n  cat <<\x27HY2_ASSET\x27\n' "$fn"
  cat "assets/$asset"
  printf '\nHY2_ASSET\n}\n'
  } >> "$tmp"
done
# shellcheck disable=SC2016 # Emit literal code into the bundle.
printf '\nif [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi\n' >> "$tmp"
bash -n "$tmp"
if [[ ${1:-} == --check ]]; then
  cmp -s "$tmp" dist/hysteria.sh || { echo '请运行 bash scripts/build.sh'; exit 1; }
else
  install -m 755 "$tmp" dist/hysteria.sh
fi
