#!/usr/bin/env bash
# Construit Tracé.app dans ./build/ (SwiftPM + toolchain Xcode), signe ad hoc et vérifie.
#
#   ./build.sh              construit et vérifie
#   ./build.sh --install    construit puis installe dans /Applications (remplace l'ancienne version)
#   ./build.sh --debug      build debug (plus rapide) pour les tests
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Tracé"
PRODUCT="Trace"
BUNDLE_ID="fr.charlesneveu.trace"
BUILD_DIR="./build"
APP_DIR="${BUILD_DIR}/${APP_NAME}.app"
MACOS_DIR="${APP_DIR}/Contents/MacOS"
RES_DIR="${APP_DIR}/Contents/Resources"
CONFIG="release"
DO_INSTALL=0
for a in "$@"; do
  case "$a" in
    --install) DO_INSTALL=1 ;;
    --debug) CONFIG="debug" ;;
  esac
done

fail() { echo ""; echo "❌ $1" >&2; exit 1; }

if [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
  SWIFT_BIN="${DEVELOPER_DIR}/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
else
  fail "Xcode introuvable dans /Applications."
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
echo "==> ${APP_NAME} ${VERSION} (${CONFIG})"

echo "==> Compilation Swift…"
"${SWIFT_BIN}" build -c "${CONFIG}" --arch arm64 --product "${PRODUCT}"
BIN_DIR="$("${SWIFT_BIN}" build -c "${CONFIG}" --arch arm64 --product "${PRODUCT}" --show-bin-path)"
BIN_PATH="${BIN_DIR}/${PRODUCT}"
[[ -x "${BIN_PATH}" ]] || fail "Binaire introuvable : ${BIN_PATH}"

echo "==> Assemblage de ${APP_NAME}.app…"
rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RES_DIR}"
cp "${BIN_PATH}" "${MACOS_DIR}/${PRODUCT}"
cp "Resources/Info.plist" "${APP_DIR}/Contents/Info.plist"
# Bundle de ressources SwiftPM (Assets) s'il existe.
if compgen -G "${BIN_DIR}/${PRODUCT}_${PRODUCT}.bundle" > /dev/null; then
  cp -R "${BIN_DIR}/${PRODUCT}_${PRODUCT}.bundle" "${RES_DIR}/"
fi
if [[ ! -f "Resources/AppIcon.icns" ]]; then
  echo "==> Génération de l'icône…"
  "${SWIFT_BIN}" make-icon.swift Resources/AppIcon.icns
fi
cp "Resources/AppIcon.icns" "${RES_DIR}/AppIcon.icns"
echo "fr" > "${RES_DIR}/.lproj_marker" && rm -f "${RES_DIR}/.lproj_marker"
mkdir -p "${RES_DIR}/fr.lproj"
echo 'APPL????' > "${APP_DIR}/Contents/PkgInfo"

echo "==> Signature ad hoc…"
codesign --force --sign - --identifier "${BUNDLE_ID}" "${APP_DIR}"
codesign --verify --strict --verbose=1 "${APP_DIR}" 2>&1 | sed 's/^/    /' || fail "Signature invalide."

echo "==> OK : ${APP_DIR}"

if [[ "${DO_INSTALL}" == "1" ]]; then
  echo "==> Installation dans /Applications…"
  osascript -e "tell application id \"${BUNDLE_ID}\" to quit" 2>/dev/null || true
  sleep 1
  rm -rf "/Applications/${APP_NAME}.app"
  cp -R "${APP_DIR}" "/Applications/${APP_NAME}.app"
  echo "==> Installé : /Applications/${APP_NAME}.app"
fi
