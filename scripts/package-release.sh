#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SCHEME=${SCHEME:-sidekick}
CONFIGURATION=${CONFIGURATION:-Release}
PACKAGE_NAME=${APP_NAME:-}
BUNDLE_IDENTIFIER=${BUNDLE_IDENTIFIER:-com.lycaennaa.sidekick}
CANONICAL_BUNDLE_IDENTIFIER=com.lycaennaa.sidekick
VERSION=${VERSION:-}
DIST_DIR=${DIST_DIR:-$ROOT/dist}
DERIVED_DATA=${DERIVED_DATA:-$ROOT/.build/package-derived-data}
PREBUILT_APP_PATH=${PREBUILT_APP_PATH:-}
# Keychain and UserNotifications require a stable signed app identity.
CODE_SIGNING_ALLOWED=NO
CODE_SIGNING_REQUIRED=NO
# Ad hoc signing avoids Apple ID access while giving this build a code identity.
CODE_SIGN_IDENTITY=-
CODE_SIGN_REQUIREMENT="=designated => identifier \"$BUNDLE_IDENTIFIER\""
if [ "$BUNDLE_IDENTIFIER" != "$CANONICAL_BUNDLE_IDENTIFIER" ]; then
    printf 'BUNDLE_IDENTIFIER must remain %s\n' "$CANONICAL_BUNDLE_IDENTIFIER" >&2
    exit 2
fi

case "$PACKAGE_NAME" in
    */*)
        printf '%s\n' 'APP_NAME must not contain a slash' >&2
        exit 2
        ;;
esac

if [ -z "$PREBUILT_APP_PATH" ]; then
    for command in curl python3 shasum xcodegen xcodebuild; do
        if ! command -v "$command" >/dev/null 2>&1; then
            printf 'Required command not found: %s\n' "$command" >&2
            exit 1
        fi
    done
    sh "$ROOT/scripts/fetch-clearurls-rules.sh" --force
    xcodegen generate --spec "$ROOT/project.yml"
fi

PROJECT_PATH=$ROOT/Sidekick.xcodeproj
if [ ! -f "$PROJECT_PATH/project.pbxproj" ]; then
    printf 'Xcode project not found: %s\n' "$PROJECT_PATH" >&2
    exit 1
fi

for command in codesign ditto hdiutil plutil strip xattr python3 unzip; do
    if ! command -v "$command" >/dev/null 2>&1; then
        printf 'Required command not found: %s\n' "$command" >&2
        exit 1
    fi
done

case "$DERIVED_DATA" in
    "$ROOT/.build"/*) ;;
    *)
        printf 'DERIVED_DATA must stay inside %s/.build\n' "$ROOT" >&2
        exit 2
        ;;
esac
rm -rf "$DERIVED_DATA"
mkdir -p "$DERIVED_DATA" "$DIST_DIR"

APP_PATH=$PREBUILT_APP_PATH
if [ -z "$APP_PATH" ]; then
    xcodebuild \
        -project "$PROJECT_PATH" \
        -scheme "$SCHEME" \
        -configuration "$CONFIGURATION" \
        -derivedDataPath "$DERIVED_DATA" \
        -clonedSourcePackagesDirPath "$ROOT/.build/source-packages" \
        "PRODUCT_BUNDLE_IDENTIFIER=$BUNDLE_IDENTIFIER" \
        STRIP_INSTALLED_PRODUCT=YES \
        COPY_PHASE_STRIP=YES \
        "CODE_SIGNING_ALLOWED=$CODE_SIGNING_ALLOWED" \
        "CODE_SIGN_IDENTITY=$CODE_SIGN_IDENTITY" \
        "CODE_SIGNING_REQUIRED=$CODE_SIGNING_REQUIRED" \
        build

    PRODUCTS_DIR=$DERIVED_DATA/Build/Products/$CONFIGURATION
    for candidate in "$PRODUCTS_DIR"/*.app; do
        if [ ! -d "$candidate" ]; then
            continue
        fi
        if [ -n "$APP_PATH" ]; then
            printf 'Multiple app products found in %s\n' "$PRODUCTS_DIR" >&2
            exit 1
        fi
        APP_PATH=$candidate
    done
fi
if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH" ]; then
    printf 'Built app not found: %s\n' "$APP_PATH" >&2
    exit 1
fi

BUILT_APP_NAME=$(basename "$APP_PATH" .app)
PACKAGE_NAME=${PACKAGE_NAME:-$BUILT_APP_NAME}
VERSION=${VERSION:-$(plutil -extract CFBundleShortVersionString raw -o - "$APP_PATH/Contents/Info.plist")}
case "$VERSION" in
    ''|*[!A-Za-z0-9._-]*)
        printf '%s\n' 'VERSION must contain only letters, numbers, dots, underscores, or hyphens' >&2
        exit 2
        ;;
esac

EXECUTABLE_PATH=$APP_PATH/Contents/MacOS/$BUILT_APP_NAME
if [ ! -f "$EXECUTABLE_PATH" ]; then
    printf 'App executable not found: %s\n' "$EXECUTABLE_PATH" >&2
    exit 1
fi
INFO_PLIST=$APP_PATH/Contents/Info.plist
plutil -replace NSUserNotificationAlertStyle -string alert "$INFO_PLIST" 2>/dev/null ||
    plutil -insert NSUserNotificationAlertStyle -string alert "$INFO_PLIST"
strip -x "$EXECUTABLE_PATH"
codesign --force --deep --options runtime --sign "$CODE_SIGN_IDENTITY" --identifier "$BUNDLE_IDENTIFIER" -r "$CODE_SIGN_REQUIREMENT" "$APP_PATH"
xattr -rc "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"
python3 "$ROOT/scripts/check-release-privacy.py" "$APP_PATH" "$ROOT"

STAGE_DIR=$(mktemp -d "$ROOT/.build/package-stage.XXXXXX")
cleanup() {
    rm -rf "$STAGE_DIR"
    rm -rf "$DERIVED_DATA"
}
trap cleanup EXIT HUP INT TERM

ditto "$APP_PATH" "$STAGE_DIR/$BUILT_APP_NAME.app"
ln -s /Applications "$STAGE_DIR/Applications"

ZIP_PATH=$DIST_DIR/$PACKAGE_NAME-$VERSION.zip
DMG_PATH=$DIST_DIR/$PACKAGE_NAME-$VERSION.dmg
rm -f "$ZIP_PATH" "$DMG_PATH"

ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"
hdiutil create -quiet -volname "$PACKAGE_NAME" -srcfolder "$STAGE_DIR" -ov -format UDZO "$DMG_PATH"
unzip -t "$ZIP_PATH" >/dev/null
hdiutil verify "$DMG_PATH" >/dev/null
xattr -c "$ZIP_PATH" "$DMG_PATH"

printf 'Created:\n  %s\n  %s\n' "$ZIP_PATH" "$DMG_PATH"