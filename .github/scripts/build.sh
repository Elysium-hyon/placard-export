#!/usr/bin/env bash
# 云端构建：不签名 archive → package-ipa.py 打 ad-hoc 签名的 IPA → 校验 App Group
# 由 .github/workflows/build-unsigned.yml 调用
set -euo pipefail

: "${RUNNER_TEMP:?RUNNER_TEMP is required}"

BUNDLE_ID="${BUNDLE_ID:-me.ssus.placard}"
VERSION="${VERSION:-$(sed -n 's/.*MARKETING_VERSION = \([^;]*\);/\1/p' placard.xcodeproj/project.pbxproj | head -n 1)}"
[ -n "$VERSION" ] || { echo "::error::cannot read MARKETING_VERSION"; exit 1; }

echo "bundle id: $BUNDLE_ID"
echo "version:   $VERSION"

mkdir -p build
rm -f build/*.ipa

xcodebuild archive \
  -project placard.xcodeproj \
  -scheme placard \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -archivePath "$RUNNER_TEMP/placard.xcarchive" \
  -derivedDataPath "$RUNNER_TEMP/DerivedData" \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  MARKETING_VERSION="$VERSION"

APP="$RUNNER_TEMP/placard.xcarchive/Products/Applications/placard.app"

# INFOPLIST_KEY_UIFileSharingEnabled 在 Xcode 里不生效（不在可注入的键表里），
# 只能在这里补，补完再签名打包。
for key in UIFileSharingEnabled LSSupportsOpeningDocumentsInPlace; do
  if ! /usr/libexec/PlistBuddy -c "Add :$key bool true" "$APP/Info.plist" 2>/dev/null; then
    /usr/libexec/PlistBuddy -c "Set :$key true" "$APP/Info.plist"
  fi
  echo "$key = $(/usr/libexec/PlistBuddy -c "Print :$key" "$APP/Info.plist")"
done

python3 .github/scripts/package-ipa.py \
  --app "$APP" \
  --output "build/placard-v${VERSION}-unsigned.ipa"

# 校验要针对「打好包的 IPA」，archive 里那个 app 本来就没签名
rm -rf "$RUNNER_TEMP/verify"
mkdir -p "$RUNNER_TEMP/verify"
ditto -x -k "build/placard-v${VERSION}-unsigned.ipa" "$RUNNER_TEMP/verify"
APP="$RUNNER_TEMP/verify/Payload/placard.app"

echo "built: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist") $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Info.plist")"
codesign --verify --strict "$APP" && echo "signature: ok"
/usr/libexec/PlistBuddy -c "Print :UIFileSharingEnabled" "$APP/Info.plist" >/dev/null \
  || { echo "::error::UIFileSharingEnabled missing"; exit 1; }

codesign -d --entitlements :- "$APP" > "$RUNNER_TEMP/entitlements.plist" 2>/dev/null || true
cat "$RUNNER_TEMP/entitlements.plist"
grep -q "application-groups" "$RUNNER_TEMP/entitlements.plist" \
  || { echo "::error::App Group entitlement missing, worse_query will not work"; exit 1; }

ls -lh build/
shasum -a 256 build/*.ipa
