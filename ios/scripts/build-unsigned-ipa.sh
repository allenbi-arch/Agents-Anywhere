#!/usr/bin/env bash
#
# Build an UNSIGNED .ipa from the iOS Xcode project.
#
# This script requires macOS with Xcode 26.5+ (IPHONEOS_DEPLOYMENT_TARGET = 26.5).
# It performs NO code signing: all signing settings are disabled on the xcodebuild
# command line, so no Apple Developer account, certificate, or provisioning
# profile is needed.
#
# Usage:
#   ./ios/scripts/build-unsigned-ipa.sh [-o OUTPUT_DIR] [-c CONFIG] [-v VERSION] [-b BUILD]
#
# Output:
#   <OUTPUT_DIR>/AgentsAnywhere-<VERSION>-<BUILD>-unsigned.ipa
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_DIR="${IOS_DIR}/Agents Anywhere"
PROJECT="${PROJECT_DIR}/Agents Anywhere.xcodeproj"
SCHEME="Agents Anywhere"
TARGET="Agents Anywhere"
APP_NAME="Agents Anywhere"

OUTPUT_DIR="${PWD}/build/ios"
CONFIGURATION="Release"
VERSION=""
BUILD_NUMBER=""

while getopts "o:c:v:b:h" opt; do
  case "${opt}" in
    o) OUTPUT_DIR="${OPTARG}" ;;
    c) CONFIGURATION="${OPTARG}" ;;
    v) VERSION="${OPTARG}" ;;
    b) BUILD_NUMBER="${OPTARG}" ;;
    h) sed -n '2,15p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "Unknown option: -${OPTARG}" >&2; exit 2 ;;
  esac
done

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- preflight
[[ "$(uname -s)" == "Darwin" ]] || die "This script must run on macOS (found: $(uname -s))."

command -v xcodebuild >/dev/null 2>&1 || die "xcodebuild not found. Install Xcode."
command -v xcrun     >/dev/null 2>&1 || die "xcrun not found. Install Xcode command line tools."

[[ -d "${PROJECT}" ]] || die "Xcode project not found at: ${PROJECT}"

XCODE_VERSION="$(xcodebuild -version | head -n1 | awk '{print $2}')"
log "Xcode ${XCODE_VERSION} detected"

# The project targets iOS 26.5, which requires the iOS 26.5 SDK (Xcode 26.5+).
IOS_SDK_VERSION="$(xcrun --sdk iphoneos --show-sdk-version 2>/dev/null || echo "unknown")"
log "iPhoneOS SDK: ${IOS_SDK_VERSION}"
if [[ "${IOS_SDK_VERSION}" != "unknown" ]]; then
  SDK_MAJOR="${IOS_SDK_VERSION%%.*}"
  if [[ "${SDK_MAJOR}" -lt 26 ]]; then
    log "WARNING: iOS SDK ${IOS_SDK_VERSION} is older than the project's"
    log "         IPHONEOS_DEPLOYMENT_TARGET (26.5). The build will likely fail."
    log "         Upgrade to Xcode 26.5 or newer."
  fi
fi

mkdir -p "${OUTPUT_DIR}"
OUTPUT_DIR="$(cd "${OUTPUT_DIR}" && pwd)"

BUILD_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/aa-ios-build.XXXXXX")"
ARCHIVE_PATH="${BUILD_ROOT}/${APP_NAME}.xcarchive"
EXPORT_DIR="${BUILD_ROOT}/export"
APP_PATH="${ARCHIVE_PATH}/Products/Applications/${APP_NAME}.app"
trap 'rm -rf "${BUILD_ROOT}"' EXIT

# ------------------------------------------------------------------ archive
# Every signing knob is forced off. This is the core of "unsigned" builds:
#   CODE_SIGNING_ALLOWED=NO          - do not invoke codesign at all
#   CODE_SIGNING_REQUIRED=NO         - do not fail when the binary is unsigned
#   CODE_SIGNING_ALLOWED=NO + EXPANDED_CODE_SIGN_IDENTITY=""
#   CODE_SIGN_IDENTITY=""            - no identity to sign with
#   CODE_SIGN_ENTITLEMENTS=""        - drop entitlements (they require signing)
#   CODE_SIGN_STYLE=Manual           - stop Xcode from trying automatic signing
#   DEVELOPMENT_TEAM=""              - detach the hardcoded team from the pbxproj
log "Archiving (${CONFIGURATION})..."

ARCHIVE_ARGS=(
  -project "${PROJECT}"
  -scheme "${SCHEME}"
  -configuration "${CONFIGURATION}"
  -destination "generic/platform=iOS"
  -archivePath "${ARCHIVE_PATH}"
  -sdk iphoneos
  ONLY_ACTIVE_ARCH=NO
  CODE_SIGNING_ALLOWED=NO
  CODE_SIGNING_REQUIRED=NO
  CODE_SIGN_IDENTITY=""
  EXPANDED_CODE_SIGN_IDENTITY=""
  CODE_SIGN_ENTITLEMENTS=""
  CODE_SIGN_STYLE=Manual
  DEVELOPMENT_TEAM=""
  PROVISIONING_PROFILE_SPECIFIER=""
  ENABLE_USER_SCRIPT_SANDBOXING=NO
)

if [[ -n "${VERSION}" ]]; then
  ARCHIVE_ARGS+=(MARKETING_VERSION="${VERSION}")
fi
if [[ -n "${BUILD_NUMBER}" ]]; then
  ARCHIVE_ARGS+=(CURRENT_PROJECT_VERSION="${BUILD_NUMBER}")
fi

xcodebuild "${ARCHIVE_ARGS[@]}" archive

[[ -d "${APP_PATH}" ]] || die "Archive succeeded but .app not found at: ${APP_PATH}"

# ------------------------------------------------------- read final metadata
PLIST="${APP_PATH}/Info.plist"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${PLIST}" 2>/dev/null || echo "com.agentsanywhere.app")"
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${PLIST}" 2>/dev/null || echo "0.0.0")"
APP_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${PLIST}" 2>/dev/null || echo "0")"

log "Bundle ID: ${BUNDLE_ID}"
log "Version:   ${APP_VERSION} (${APP_BUILD})"

# ------------------------------------------------------------- package .ipa
# An .ipa is just a zip whose root contains a single "Payload/" directory
# holding the .app bundle. No signing happens here.
log "Packaging unsigned .ipa..."

mkdir -p "${EXPORT_DIR}/Payload"
cp -R "${APP_PATH}" "${EXPORT_DIR}/Payload/"

# Best-effort: strip any signature that may have been embedded by the SDK.
# An unsigned IPA normally has none, but stale _CodeSignature dirs break
# re-signing tools (Sideloadly / AltStore / zsign), so remove them.
find "${EXPORT_DIR}/Payload" -type d -name "_CodeSignature" -prune -exec rm -rf {} + 2>/dev/null || true
find "${EXPORT_DIR}/Payload" -name "CodeResources" -delete 2>/dev/null || true

IPA_NAME="AgentsAnywhere-${APP_VERSION}-${APP_BUILD}-unsigned.ipa"
IPA_PATH="${OUTPUT_DIR}/${IPA_NAME}"

rm -f "${IPA_PATH}"
# ditto preserves resource forks / symlinks correctly; fall back to zip.
if command -v ditto >/dev/null 2>&1; then
  ( cd "${EXPORT_DIR}" && ditto -c -k --sequesterRsrc --keepParent Payload "${IPA_PATH}" )
else
  ( cd "${EXPORT_DIR}" && zip -qry "${IPA_PATH}" Payload )
fi

[[ -f "${IPA_PATH}" ]] || die "Failed to create ${IPA_PATH}"

# ------------------------------------------------------------------ report
IPA_SIZE="$(du -h "${IPA_PATH}" | cut -f1)"
SHA256="$(shasum -a 256 "${IPA_PATH}" | awk '{print $1}')"

# Verify the payload layout is what an IPA consumer expects.
if ! unzip -l "${IPA_PATH}" | grep -q "Payload/${APP_NAME}.app/"; then
  log "WARNING: Payload layout looks unexpected; inspect with: unzip -l '${IPA_PATH}'"
fi

# Verify the binary architecture (should include arm64 for real devices).
BINARY="${APP_PATH}/${APP_NAME}"
if [[ -f "${BINARY}" ]]; then
  ARCHS="$(lipo -archs "${BINARY}" 2>/dev/null || echo "unknown")"
  log "Binary arch: ${ARCHS}"
fi

echo
echo "======================================================================"
echo " Unsigned IPA built successfully"
echo "======================================================================"
echo " Path:    ${IPA_PATH}"
echo " Size:    ${IPA_SIZE}"
echo " SHA-256: ${SHA256}"
echo
echo " This IPA is NOT signed and will NOT install on a device as-is."
echo " Install it with a signing tool that applies your own certificate:"
echo "   - Sideloadly (Windows/macOS, uses your Apple ID)"
echo "   - AltStore / SideStore (needs a pairing file)"
echo "   - zsign / ldid (command line)"
echo
echo " On macOS you can also re-sign it for the simulator-free device flow:"
echo "   codesign -f -s 'Apple Development: you@example.com' \\"
echo "     --entitlements entitlements.plist 'Payload/${APP_NAME}.app'"
echo "======================================================================"
