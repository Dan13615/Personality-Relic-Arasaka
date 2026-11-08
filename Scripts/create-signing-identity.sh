#!/bin/bash
# Crée une identité de signature locale « Capri Dev » (certificat auto-signé) dans ton trousseau.
#
# Pourquoi ? Avec la signature « ad hoc » (codesign -s -), chaque recompilation change l'identité
# de Capri.app : macOS peut alors redemander l'accès à l'agenda et aux dossiers. Avec une identité
# stable, les autorisations survivent aux recompilations. Ce certificat ne sert QU'à signer Capri
# sur ton Mac : il n'est reconnu par aucun autre ordinateur.
#
# À lancer une seule fois, toi-même :  ./Scripts/create-signing-identity.sh
set -euo pipefail

NAME="Capri Dev"
if security find-identity -p codesigning | grep -q "\"$NAME\""; then
    echo "L'identité « $NAME » existe déjà."
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

cat > cert.cnf <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

echo "▸ Création du certificat (valable 10 ans)"
openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 3650 -config cert.cnf 2>/dev/null
openssl pkcs12 -export -inkey key.pem -in cert.pem -out capri.p12 -passout pass:capri -name "$NAME"

echo "▸ Import dans le trousseau « session » (autorisé pour codesign uniquement)"
security import capri.p12 -k ~/Library/Keychains/login.keychain-db -P capri -T /usr/bin/codesign

echo "▸ Confiance pour la signature de code (macOS va te demander ton mot de passe)"
security add-trusted-cert -r trustRoot -p codeSign -k ~/Library/Keychains/login.keychain-db cert.pem

echo
security find-identity -v -p codesigning | grep "$NAME" && echo "✓ Prêt. Relance ./Scripts/run.sh : Capri sera signée avec « $NAME »."
