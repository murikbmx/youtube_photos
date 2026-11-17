#!/usr/bin/env bash
# Packs an APK patched elsewhere (e.g. in Morphe Manager) into a root module (KernelSU/Magisk).
#
#   ./repack.sh <App> <patched.apk> [stock.apk|stock.apkm]
#
# <App> is one of apps.sh (YouTube, GooglePhotos).
# Without a stock file the original of the same version is downloaded from GitHub releases:
#   1) INPUT_REPO, release INPUT_TAG (default 'input'), if INPUT_REPO is set
#   2) STOCK_REPO, release STOCK_TAG (default murikbmx/morphe-module, 'stock-apks')
# as <package>-<version>-<arch>.apk(m) or <package>-<version>-all.apk(m).
#
# Env: VERSION_CODE (module versionCode, default: date), UPDATE_JSON (module update url, optional),
#      GITHUB_TOKEN, JAVA, AAPT2, ZIPALIGN (default: newest Android build-tools from ANDROID_HOME).
# Output: build/<prefix>-module-v<version>-<arch>.zip and build/notes.md

set -euo pipefail
cd "$(dirname "$0")"
source apps.sh

TEMP_DIR=temp BUILD_DIR=build
STOCK_REPO=${STOCK_REPO:-murikbmx/morphe-module} STOCK_TAG=${STOCK_TAG:-stock-apks}
INPUT_REPO=${INPUT_REPO:-} INPUT_TAG=${INPUT_TAG:-input}
JAVA=${JAVA:-java}
APKSIGNER=bin/apksigner.jar

pr() { echo -e "\033[0;32m[+] ${1}\033[0m" >&2; }
abort() {
	echo -e "\033[0;31m[-] ${1}\033[0m" >&2
	if [ -n "${GITHUB_STEP_SUMMARY-}" ]; then printf '### ⚠️ Модуль не собран\n%s\n' "$1" >>"$GITHUB_STEP_SUMMARY"; fi
	exit 1
}

if [ $# -lt 2 ]; then abort "Usage: $0 <App> <patched.apk> [stock.apk|stock.apkm]"; fi
APP=$1 PATCHED=$2 STOCK_IN=${3-}
if ! declare -F "app_${APP}" >/dev/null; then
	abort "Unknown app '${APP}'. Known: $(declare -F | sed -n 's/.* app_//p' | paste -sd ' ' -)"
fi
"app_${APP}"
[ -f "$PATCHED" ] || abort "File not found: $PATCHED"

find_tool() {
	local name=$1 var=$2 sdk d
	if [ -n "${!var-}" ]; then echo "${!var}"; return; fi
	if command -v "$name" >/dev/null; then command -v "$name"; return; fi
	for sdk in "${ANDROID_HOME-}" "${ANDROID_SDK_ROOT-}"; do
		[ -d "$sdk/build-tools" ] || continue
		d=$(ls -1 "$sdk/build-tools" | sort -V | tail -1)
		if [ -x "$sdk/build-tools/$d/$name" ]; then echo "$sdk/build-tools/$d/$name"; return; fi
	done
	abort "'$name' not found: install Android SDK build-tools (set ANDROID_HOME) or set $var"
}
AAPT2=$(find_tool aapt2 AAPT2)
ZIPALIGN=$(find_tool zipalign ZIPALIGN)
"$JAVA" -version >/dev/null 2>&1 || abort "java not found (set JAVA)"
mkdir -p "$TEMP_DIR" "$BUILD_DIR"

badging() { "$AAPT2" dump badging "$1" 2>/dev/null | head -1; }
badging_val() { sed -n "s/.* ${2}='\([^']*\)'.*/\1/p" <<<"$1"; }
cert_sha256() { "$JAVA" -jar "$APKSIGNER" verify --print-certs "$1" 2>/dev/null | grep -m1 'certificate SHA-256 digest' | awk '{print $NF}'; }
gh_api() { curl -fsSL ${GITHUB_TOKEN:+-H "Authorization: token ${GITHUB_TOKEN}"} "$@"; }

# ---- the patched apk ----
B=$(badging "$PATCHED") || :
[ -n "$B" ] || abort "'$PATCHED' is not an apk (aapt2 cannot read it)"
P_PKG=$(badging_val "$B" name) VERSION=$(badging_val "$B" versionName)
pr "Patched apk: ${P_PKG} ${VERSION}"
if [ "$P_PKG" != "$PKG" ]; then
	abort "В пропатченном APK пакет '${P_PKG}', а нужен '${PKG}'. Для root-модуля пропатчите заново с ОТКЛЮЧЁННЫМ патчем GmsCore support (MicroG): он меняет имя пакета."
fi
[ -n "$VERSION" ] || abort "Cannot read the version of '$PATCHED'"
if [ "$(cert_sha256 "$PATCHED")" = "$STOCK_SIG" ]; then
	abort "'$PATCHED' is signed by Google: it is the original, not a patched apk"
fi

# ---- the stock apk ----
STOCK="${TEMP_DIR}/${PKG}-${VERSION}-${ARCH}.apk"
merge_splits() {
	local bundle=$1 output=$2 dlurl
	pr "Merging splits of $bundle"
	if [ ! -f "$TEMP_DIR/apkeditor.jar" ]; then
		dlurl=$(gh_api "https://api.github.com/repos/REAndroid/APKEditor/releases/latest" |
			jq -e -r '[.assets[] | select(.name | endswith(".jar"))][0].browser_download_url') || abort "Cannot find APKEditor"
		curl -fsSL -o "$TEMP_DIR/apkeditor.jar" "$dlurl"
	fi
	rm -f "${output}-unsigned"
	"$JAVA" -jar "$TEMP_DIR/apkeditor.jar" merge -i "$bundle" -o "${output}-unsigned" -clean-meta -f >&2 || abort "APKEditor failed on $bundle"
	sign "${output}-unsigned" "$output"
	rm -f "${output}-unsigned"
}
sign() {
	"$JAVA" -jar "$APKSIGNER" sign --ks ks-p12.keystore --ks-pass pass:123456789 --key-pass pass:123456789 \
		--ks-key-alias jhc --out "$2" "$1" || abort "apksigner failed on $1"
	rm -f "$2.idsig"
}
fetch_stock() {
	local repo=$1 tag=$2 resp name url
	resp=$(gh_api "https://api.github.com/repos/${repo}/releases/tags/${tag}") || return 1
	for name in "${PKG}-${VERSION}-${ARCH}.apkm" "${PKG}-${VERSION}-${ARCH}.apk" "${PKG}-${VERSION}-all.apkm" "${PKG}-${VERSION}-all.apk"; do
		url=$(jq -r --arg n "$name" '.assets[] | select(.name == $n) | .url' <<<"$resp")
		[ -n "$url" ] || continue
		pr "Downloading stock ${name} from ${repo} (${tag})"
		gh_api -H "Accept: application/octet-stream" -o "${TEMP_DIR}/${name}" "$url" || return 1
		echo "${TEMP_DIR}/${name}"
		return 0
	done
	return 1
}
if [ -z "$STOCK_IN" ]; then
	if [ -n "$INPUT_REPO" ]; then STOCK_IN=$(fetch_stock "$INPUT_REPO" "$INPUT_TAG") || STOCK_IN=""; fi
	if [ -z "$STOCK_IN" ]; then STOCK_IN=$(fetch_stock "$STOCK_REPO" "$STOCK_TAG") || STOCK_IN=""; fi
	[ -n "$STOCK_IN" ] || abort "Оригинал ${PKG} ${VERSION} не найден. Загрузите его в релиз '${INPUT_TAG}' с именем ${PKG}-${VERSION}-${ARCH}.apk (или .apkm для split-архива) и запустите снова."
fi
[ -f "$STOCK_IN" ] || abort "File not found: $STOCK_IN"
case "$STOCK_IN" in
*.apkm | *.apks | *.xapk) merge_splits "$STOCK_IN" "$STOCK" ;;
*) [ "$STOCK_IN" -ef "$STOCK" ] || cp -f "$STOCK_IN" "$STOCK" ;;
esac

B=$(badging "$STOCK") || :
S_PKG=$(badging_val "$B" name) S_VER=$(badging_val "$B" versionName)
pr "Stock apk: ${S_PKG} ${S_VER}"
[ "$S_PKG" = "$PKG" ] || abort "Оригинал: пакет '${S_PKG}', а нужен '${PKG}'"
[ "$S_VER" = "$VERSION" ] || abort "Версии не совпадают: оригинал ${S_VER}, пропатченный ${VERSION}. Нужен оригинал той же версии."
# a merged bundle is re-signed: check the signature of its base apk instead
if [[ "$STOCK_IN" != *.apk ]]; then
	rm -rf "${TEMP_DIR}/bundle" && mkdir -p "${TEMP_DIR}/bundle"
	unzip -qo -j "$STOCK_IN" 'base.apk' -d "${TEMP_DIR}/bundle" || abort "No base.apk in $STOCK_IN"
	SIG=$(cert_sha256 "${TEMP_DIR}/bundle/base.apk")
	rm -rf "${TEMP_DIR}/bundle"
else
	SIG=$(cert_sha256 "$STOCK")
fi
# STOCK_REPO keeps bundles merged and re-signed with the builder key (5aad...): morphe-module checked
# the Google signature before merging, so that key is accepted for files from there
MERGE_SIG=5aad2bee6db95d17e05a08d7d1e64c10a1511879154483916b6ae6c7fd9cb0c6
[ "$SIG" = "$STOCK_SIG" ] || [ "$SIG" = "$MERGE_SIG" ] || abort "Подпись оригинала (${SIG:-нет}) не совпадает с подписью Google. Файл подозрительный, не используем."
unzip -l "$STOCK" "lib/${ARCH}/*" >/dev/null 2>&1 || abort "В оригинале нет библиотек для ${ARCH}"

# ---- base.apk for the module: no native libs (they are taken from the stock apk), aligned, signed ----
pr "Stripping native libs, aligning and signing"
BASE="${TEMP_DIR}/${FILE_PREFIX}-${VERSION}-base.apk"
cp -f "$PATCHED" "${BASE}.tmp"
if unzip -l "${BASE}.tmp" 'lib/*' >/dev/null 2>&1; then zip -qd "${BASE}.tmp" 'lib/*'; fi
rm -f "${BASE}.aligned"
"$ZIPALIGN" -f 4 "${BASE}.tmp" "${BASE}.aligned" || abort "zipalign failed"
sign "${BASE}.aligned" "$BASE"
rm -f "${BASE}.tmp" "${BASE}.aligned"
"$JAVA" -jar "$APKSIGNER" verify "$BASE" || abort "base.apk does not verify"

# ---- the module ----
MA=""
case "$ARCH" in arm64-v8a) MA=arm64 ;; arm-v7a | armeabi-v7a) MA=arm ;; esac
VERSION_CODE=${VERSION_CODE:-$(date +%Y%m%d)}
T=$(mktemp -d -p "$TEMP_DIR")
cp -a module/. "$T"
printf 'PKG_NAME=%s\nPKG_VER=%s\nMODULE_ARCH=%s\n' "$PKG" "$VERSION" "$MA" >"$T/config"
{
	echo "id=${MODULE_ID}"
	echo "name=${MODULE_NAME}"
	echo "version=v${VERSION} (Morphe Manager)"
	echo "versionCode=${VERSION_CODE}"
	echo "author=murikbmx"
	echo "description=${MODULE_NAME} module (patched in Morphe Manager)"
	if [ -n "${UPDATE_JSON-}" ]; then echo "updateJson=${UPDATE_JSON}"; fi
} >"$T/module.prop"
cp -f "$BASE" "$T/base.apk"
mkdir -p "$T/stock"
cp -f "$STOCK" "$T/stock/base.apk"
OUT="${BUILD_DIR}/${FILE_PREFIX}-module-v${VERSION}-${ARCH}.zip"
rm -f "$OUT"
(cd "$T" && zip -9 -qr "${OLDPWD}/${OUT}" .)
rm -rf "$T"

size() { du -h "$1" | cut -f1; }
{
	echo "${APP}: ${VERSION}  "
	echo "Root module (KernelSU/Magisk) from an APK patched in Morphe Manager.  "
	echo "base.apk $(size "$BASE") (without native libs), stock $(size "$STOCK"), module $(size "$OUT")  "
	echo ""
} >>"${BUILD_DIR}/notes.md"
rm -f "$BASE"
pr "Built: $OUT ($(size "$OUT"))"
echo "$OUT"
