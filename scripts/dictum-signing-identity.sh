#!/usr/bin/env bash
set -euo pipefail

identity_name="dictum Local Signing"
keychain="$HOME/Library/Keychains/login.keychain-db"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

find_identity() {
  security find-identity -p codesigning "$keychain" |
    awk -v name="\"$identity_name\"" 'index($0, name) && !found++ { print $2 }'
}

if [[ -n "$(find_identity)" ]]; then
  printf '%s 已存在。\n' "$identity_name"
  exit 0
fi

if security find-certificate -c "$identity_name" "$keychain" >/dev/null 2>&1; then
  printf '找到同名证书，但未找到可用私钥。请在钥匙串访问中检查 %s。\n' "$identity_name" >&2
  exit 1
fi

umask 077
mkdir -p "$repo_root/.build"
temporary_dir="$(mktemp -d "$repo_root/.build/signing.XXXXXX")"
trap 'rm -rf "$temporary_dir"' EXIT
password="$(openssl rand -hex 32)"
openssl req -new -newkey rsa:2048 -nodes -x509 -days 3650 \
  -subj "/CN=$identity_name/" \
  -addext "basicConstraints=critical,CA:FALSE" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  -keyout "$temporary_dir/key.pem" -out "$temporary_dir/cert.pem"
openssl pkcs12 -export -inkey "$temporary_dir/key.pem" \
  -in "$temporary_dir/cert.pem" -name "$identity_name" \
  -out "$temporary_dir/identity.p12" -passout "pass:$password"
printf '正在导入登录钥匙串。如果系统要求授权，请由所有者在本机处理。\n'
security import "$temporary_dir/identity.p12" -k "$keychain" \
  -P "$password" -x -T /usr/bin/codesign
[[ -n "$(find_identity)" ]] || {
  printf '未找到可用身份，构建将继续使用临时签名。\n' >&2
  exit 1
}
printf '%s 已创建。\n' "$identity_name"
