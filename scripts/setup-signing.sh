#!/bin/zsh
# Crea una identidad de firma local y persistente ("NeonSweep Dev") en el
# llavero. Sirve para que macOS (TCC) reconozca la app como la MISMA entre
# rebuilds: sin esto, la firma ad-hoc cambia en cada compilación y el sistema
# vuelve a pedir Acceso Total al Disco, Fotos, etc. una y otra vez.
#
# No sustituye a un Developer ID (no sirve para distribuir), pero resuelve el
# desarrollo local. Ejecutar una sola vez.
set -e

IDENTITY="NeonSweep Dev"

if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
    echo "La identidad '$IDENTITY' ya existe en el llavero."
    exit 0
fi

TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT

cat > "$TMP/cs.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = NeonSweep Dev
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cs.cnf" 2>/dev/null

# -legacy: el llavero de macOS no acepta el cifrado por defecto de OpenSSL 3
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/id.p12" -passout pass:neonsweep -name "$IDENTITY" 2>/dev/null

security import "$TMP/id.p12" -k ~/Library/Keychains/login.keychain-db \
    -P neonsweep -T /usr/bin/codesign -T /usr/bin/security

echo "OK: identidad '$IDENTITY' creada. Vuelve a ejecutar ./build-app.sh"
echo "Los permisos del sistema ya no se resetearán en cada compilación."
