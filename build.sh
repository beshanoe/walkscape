#!/bin/sh
# Builds build/WalkScape.app, with the WalkScape Camera extension inside, and build/backdrop-test
# (no Xcode project needed). Objective-C (frame path, cutout engines, scenes, treadmill: every .m
# under src/ but the extension's) → clang; the app's SwiftUI layer (src/app/*.swift) is compiled
# and linked with swiftc, seeing the Objective-C classes through src/app/WalkScape-Bridging.h.
# The camera extension (src/virtual-camera/extension/) is its own process and its own binary.
# Every folder under src/ is an include path: #import "X.h" works wherever X.h lives, so file
# names are unique across src/ (checked below). Scenes add themselves (SceneRegistry), so a new
# folder under src/scenes/ is a new scene with no change here.
#
# Signing:
#   - ad hoc by default. Such a build runs, but macOS won't install its camera extension.
#   - with signing/development.provisionprofile (or PROVISIONING_PROFILE=<file>): your "Apple
#     Development" certificate (or SIGN_IDENTITY), hardened runtime, the profile embedded. This
#     build can install the virtual camera once it's in /Applications.
set -eu
cd "$(dirname "$0")"
mkdir -p build/obj

MIN_MACOS=15.0
# The version, MAJOR.MINOR.PATCH, is bundle/Info.plist's CFBundleShortVersionString and nothing
# else (AGENTS.md → "Finishing a feature"): CFBundleVersion, which macOS compares, is
# set to the same string below.
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' bundle/Info.plist)
if ! echo "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "bundle/Info.plist: the version \"$VERSION\" isn't MAJOR.MINOR.PATCH" >&2
  exit 1
fi
DIRS=$(find src -type d | sort)
DUPLICATES=$(find src -type f -exec basename {} \; | sort | uniq -d)
if [ -n "$DUPLICATES" ]; then
  echo "File names must be unique across src/ (include paths, object files, shader table): $DUPLICATES" >&2
  exit 1
fi
# A scene is its folder: nothing outside src/scenes/<scene>/ may name a file in it (an #import, a
# shader list), so scenes build on host/, environments/ and kit/ and never on each other, and a
# scene can be added or removed as a folder (src/scenes/host/Scene.h → "Adding a scene").
for d in src/scenes/*/; do
  case "$(basename "$d")" in host | environments | kit) continue ;; esac
  for f in "$d"*; do
    USERS=$(grep -rlF "\"$(basename "$f")\"" src tools/backdrop-test.m | grep -v "^$d" || true)
    if [ -n "$USERS" ]; then
      echo "$f belongs to one scene but is used by:" $USERS "(move what is shared to src/scenes/kit/)" >&2
      exit 1
    fi
  done
done
CFLAGS="-fobjc-arc -fmodules -O2 -Wall -Wno-unguarded-availability-new -mmacosx-version-min=$MIN_MACOS -Ibuild $(printf -- '-I%s ' $DIRS)"
SWIFTFLAGS="-O -swift-version 6 -warnings-as-errors -target arm64-apple-macos$MIN_MACOS -module-cache-path build/swift-module-cache $(printf -- '-Xcc -I%s ' $DIRS)"
EXT_DIR=src/virtual-camera/extension
OBJC=$(find src -name '*.m' -not -path "$EXT_DIR/*" | sort)
SWIFT=$(find src -name '*.swift' | sort)
APP_ID=dev.walkscape.app
EXT_ID=dev.walkscape.app.camera

# Signing setup: the provisioning profile names the team; the team goes into the extension's
# app group and Mach service name.
if [ -n "${PROVISIONING_PROFILE+set}" ]; then
  PROFILE=$PROVISIONING_PROFILE
  if [ -n "$PROFILE" ] && [ ! -f "$PROFILE" ]; then
    echo "No provisioning profile at $PROFILE" >&2
    exit 1
  fi
elif [ -f signing/development.provisionprofile ]; then
  PROFILE=signing/development.provisionprofile
else
  PROFILE=
fi
SIGN_IDENTITY=${SIGN_IDENTITY:-}
TEAM_ID=
if [ -n "$PROFILE" ]; then
  security cms -D -i "$PROFILE" > build/profile.plist
  TEAM_ID=$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' build/profile.plist)
  PROFILE_APP_ID=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' build/profile.plist)
  if [ "$PROFILE_APP_ID" != "$TEAM_ID.$APP_ID" ]; then
    echo "$PROFILE is for $PROFILE_APP_ID, not $TEAM_ID.$APP_ID" >&2
    exit 1
  fi
  if ! /usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.system-extension.install' build/profile.plist >/dev/null 2>&1; then
    echo "$PROFILE doesn't allow system extensions: turn on the App ID's \"System Extension\" capability and download the profile again" >&2
    exit 1
  fi
  if [ -z "$SIGN_IDENTITY" ]; then
    SIGN_IDENTITY=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development: .*\)"$/\1/p' | head -n 1)
    if [ -z "$SIGN_IDENTITY" ]; then
      echo "No \"Apple Development\" certificate in the keychain." >&2
      exit 1
    fi
  fi
elif [ -n "$SIGN_IDENTITY" ]; then
  # No profile: the extension can't be installed anyway; take the team from the certificate.
  TEAM_ID=$(security find-certificate -c "$SIGN_IDENTITY" -p 2>/dev/null | openssl x509 -noout -subject 2>/dev/null | sed -n 's/.*OU *= *\([A-Z0-9]*\).*/\1/p')
fi
TEAM_ID=${TEAM_ID:-ADHOC}

# The Metal sources, compiled at runtime (Xcode 26 ships the offline compiler separately): every .h
# and .metal of each folder with a .metal file becomes an entry of kShaderFiles[] in
# build/ShaderFiles.inc, looked up by file name (ShaderFileText in src/pipeline/ShaderFiles.m).
# SceneRenderer pastes SceneShared.h + Common.metal + a scene's files into one Metal source.
SHADER_FILES=$(for d in $(find src -name '*.metal' -exec dirname {} \; | sort -u); do
  find "$d" -maxdepth 1 \( -name '*.h' -o -name '*.metal' \) | sort
done)
{
  for f in $SHADER_FILES; do
    xxd -i -n "kShader_$(basename "$f" | tr .- __)" "$f"
  done
  echo "static const struct { const char *name; const unsigned char *bytes; unsigned long length; } kShaderFiles[] = {"
  for f in $SHADER_FILES; do
    name=$(basename "$f")
    echo "  {\"$name\", kShader_$(echo "$name" | tr .- __), sizeof kShader_$(echo "$name" | tr .- __)},"
  done
  echo "};"
} > build/ShaderFiles.inc
rm -f build/SceneShaders.h build/VisionBackdropShaders.h build/ForestShaders.h
FRAMEWORKS="-framework AppKit -framework AVFoundation -framework CoreMedia -framework CoreVideo -framework CoreImage \
  -framework Metal -framework MetalPerformanceShaders -framework QuartzCore -framework VideoToolbox -framework ImageIO \
  -framework CoreMediaIO -framework SystemExtensions -framework Network -framework Vision"
EXT_FRAMEWORKS="-framework Foundation -framework CoreMediaIO -framework CoreMedia -framework CoreVideo -framework CoreImage \
  -framework CoreGraphics -framework CoreText -framework VideoToolbox"

objects() {
  for src in "$@"; do
    obj="build/obj/$(basename "${src%.m}").o"
    clang $CFLAGS -c "$src" -o "$obj"
    printf '%s ' "$obj"
  done
}
OBJ=$(objects $OBJC)

clang $CFLAGS $OBJ tools/backdrop-test.m $FRAMEWORKS -o build/backdrop-test
codesign --force --sign - build/backdrop-test >/dev/null 2>&1

# The camera extension. build/camera-extension is also left outside the app, unsandboxed, for
# `build/camera-extension --selftest <dir>`.
clang $CFLAGS $EXT_DIR/CameraExtension.m $EXT_FRAMEWORKS -o build/camera-extension
codesign --force --sign - build/camera-extension >/dev/null 2>&1

APP=build/WalkScape.app
EXT="$APP/Contents/Library/SystemExtensions/$EXT_ID.systemextension"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$EXT/Contents/MacOS"
swiftc $SWIFTFLAGS -import-objc-header src/app/WalkScape-Bridging.h $SWIFT $OBJ $FRAMEWORKS \
  -o "$APP/Contents/MacOS/WalkScape"
cp bundle/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $VERSION" "$APP/Contents/Info.plist"
cp resources/AppIcon.icns "$APP/Contents/Resources/"  # from tools/make-icon.swift

# macOS replaces an installed extension when either of its versions differs, and often starts a
# replaced camera extension only after a restart. So the extension's versions follow its own
# sources, not the app's: CFBundleVersion changes when they do, and CFBundleShortVersionString
# stays 0.1 (the app's version when the two parted; changing it would swap the extension in too).
EXT_VERSION=0.1
# These four files in this order: another list or order changes the version, and macOS swaps in
# the extension (on 27.2 it then stayed stopped until a restart).
EXT_SUM=$(cat $EXT_DIR/CameraExtension.m src/virtual-camera/VirtualCameraShared.h $EXT_DIR/CameraExtension-Info.plist $EXT_DIR/CameraExtension.entitlements | cksum | cut -d' ' -f1)
BUILD="1.$((EXT_SUM % 2147483647))"
cp build/camera-extension "$EXT/Contents/MacOS/$EXT_ID"
sed -e "s/@TEAM_ID@/$TEAM_ID/g" -e "s/@VERSION@/$EXT_VERSION/g" -e "s/@BUILD@/$BUILD/g" $EXT_DIR/CameraExtension-Info.plist > "$EXT/Contents/Info.plist"
sed "s/@TEAM_ID@/$TEAM_ID/g" $EXT_DIR/CameraExtension.entitlements > build/CameraExtension.entitlements

# Inside out: the extension, then the app.
if [ -n "$SIGN_IDENTITY" ]; then
  cp bundle/WalkScape.entitlements build/WalkScape.entitlements
  if [ -n "$PROFILE" ]; then
    # The bytes only: cp would bring the browser's download URL along, and quarantine even with -X.
    cat "$PROFILE" > "$APP/Contents/embedded.provisionprofile"
    /usr/libexec/PlistBuddy -c "Add :com.apple.developer.system-extension.install bool true" \
      -c "Add :com.apple.application-identifier string $TEAM_ID.$APP_ID" \
      -c "Add :com.apple.developer.team-identifier string $TEAM_ID" build/WalkScape.entitlements
  fi
  # SIGN_FLAGS is unquoted on purpose: it may hold several flags (e.g. --timestamp).
  codesign --force --options runtime ${SIGN_FLAGS:-} --entitlements build/CameraExtension.entitlements --sign "$SIGN_IDENTITY" "$EXT"
  codesign --force --options runtime ${SIGN_FLAGS:-} --entitlements build/WalkScape.entitlements --sign "$SIGN_IDENTITY" "$APP"
  echo "signed: $SIGN_IDENTITY, team $TEAM_ID${PROFILE:+, profile $PROFILE}"
else
  codesign --force --sign - --entitlements build/CameraExtension.entitlements "$EXT" >/dev/null
  codesign --force --sign - "$APP" >/dev/null
  echo "signed ad hoc: the virtual camera can't be installed from this build"
fi
echo "built $APP (version $VERSION) build/backdrop-test build/camera-extension"
