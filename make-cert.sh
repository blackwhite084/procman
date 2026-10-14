#!/bin/zsh
# 生成自签名代码签名证书「Procman Dev」导入登录钥匙串，只需运行一次。
# 用途：让每次编译出的 Procman 签名身份不变，系统隐私权限（屏幕录制 / 辅助功能）不用反复重新授权。
set -e
NAME="Procman Dev"
if security find-identity -p codesigning | grep -q "\"$NAME\""; then echo "证书「$NAME」已存在"; exit 0; fi
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cfg" <<CFG
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CFG
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cfg" \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" -passout pass:procman
security import "$TMP/id.p12" -k ~/Library/Keychains/login.keychain-db -P procman -T /usr/bin/codesign
echo "已生成证书「$NAME」。现在运行 ./build.sh，之后给 Procman 授权一次即可长期有效"
