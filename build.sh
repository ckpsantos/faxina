#!/bin/bash
# Compila e monta dist/Faxina.app (sem Xcode, só Command Line Tools).
# Com --instalar, também copia para /Applications e abre de lá.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="dist/Faxina.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Faxina "$APP/Contents/MacOS/Faxina"
cp Info.plist "$APP/Contents/Info.plist"
[ -f icone/AppIcon.icns ] && cp icone/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Assinatura estável (opcional): com um certificado local, a assinatura não muda a cada
# compilação e o macOS mantém as permissões já concedidas. A configuração fica em
# .assinatura.local, que não vai para o repositório. Sem ela, a assinatura é ad-hoc.
#   ASSINATURA_IDENTIDADE="nome do certificado"
#   ASSINATURA_CHAVEIRO="caminho do chaveiro"
#   ASSINATURA_SENHA="senha do chaveiro"
ASSINATURA_IDENTIDADE=""
[ -f .assinatura.local ] && source .assinatura.local
if [ -n "$ASSINATURA_IDENTIDADE" ] \
    && security unlock-keychain -p "${ASSINATURA_SENHA:-}" "${ASSINATURA_CHAVEIRO:-}" 2>/dev/null \
    && codesign --force --sign "$ASSINATURA_IDENTIDADE" "$APP" 2>/dev/null; then
    echo "Assinado com o certificado local."
else
    codesign --force --sign - "$APP"
    echo "Assinado ad-hoc (permissões serão pedidas de novo)."
fi

echo "Pronto: $APP"

if [ "${1:-}" = "--instalar" ]; then
    osascript -e 'tell application id "com.kevinsantos.faxina" to quit' 2>/dev/null || true
    sleep 2
    rm -rf "/Applications/Faxina.app"
    ditto "$APP" "/Applications/Faxina.app"
    open "/Applications/Faxina.app"
    echo "Instalado em /Applications/Faxina.app"
fi
