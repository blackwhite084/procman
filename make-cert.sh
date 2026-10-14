#!/bin/zsh
# 生成自签名代码签名证书「Procman Dev」，只需运行一次。
# 用途：让每次编译出的 Procman 签名身份不变，系统隐私权限（屏幕录制 / 辅助功能）不用反复重新授权。
#
# 证书放在单独的 procman-dev 钥匙串里（密码固定、仅用于本地签名）：
# 放进登录钥匙串的话，命令行里 codesign 取私钥会报 errSecInternalComponent，得输登录密码或点弹窗
set -e
NAME="Procman Dev"
KC="$HOME/Library/Keychains/procman-dev.keychain-db"
PW="procman"
if security find-identity -p codesigning "$KC" 2>/dev/null | grep -q "\"$NAME\""; then echo "证书「$NAME」已存在"; exit 0; fi
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
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" -passout pass:$PW
[ -f "$KC" ] || security create-keychain -p "$PW" "$KC"
security set-keychain-settings "$KC"   # 不自动上锁
security unlock-keychain -p "$PW" "$KC"
security import "$TMP/id.p12" -k "$KC" -P "$PW" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PW" "$KC" >/dev/null
# 加入钥匙串搜索列表，codesign 才找得到
security list-keychains -d user -s $(security list-keychains -d user | tr -d '"') "$KC"
echo "已生成证书「$NAME」。现在运行 ./build.sh，之后给 Procman 授权一次即可长期有效"
