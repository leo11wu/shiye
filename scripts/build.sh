#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_BUILD="$TASK_ROOT/.build/native"
TASK_RELEASE="${1:-$TASK_ROOT/release}"
TASK_STAGE="$(mktemp -d /private/tmp/shiye-build.XXXXXX)"
TASK_APP="$TASK_STAGE/拾页.app"
mkdir -p "$TASK_BUILD/Resources/Fonts" "$TASK_BUILD/Resources/OCR" "$TASK_APP/Contents/MacOS" "$TASK_APP/Contents/Frameworks" "$TASK_APP/Contents/Resources/Fonts" "$TASK_APP/Contents/Resources/OCR" "$TASK_RELEASE"
cp "$TASK_ROOT"/Sources/PageArchiveCore/Resources/Fonts/* "$TASK_BUILD/Resources/Fonts/"
cp "$TASK_ROOT/Sources/PageArchiveCore/Resources/OCR/SKILL.md" "$TASK_BUILD/Resources/OCR/"
xcrun swiftc -O -g -target arm64-apple-macosx14.0 -module-cache-path "$TASK_BUILD/module-cache" -enable-testing -emit-library -emit-module -module-name PageArchiveCore -emit-module-path "$TASK_BUILD/PageArchiveCore.swiftmodule" -Xlinker -install_name -Xlinker @rpath/libPageArchiveCore.dylib "$TASK_ROOT"/Sources/PageArchiveCore/*.swift -o "$TASK_BUILD/libPageArchiveCore.dylib"
xcrun swiftc -O -target arm64-apple-macosx14.0 -module-cache-path "$TASK_BUILD/module-cache" -I "$TASK_BUILD" -L "$TASK_BUILD" -lPageArchiveCore -Xlinker -rpath -Xlinker @loader_path "$TASK_ROOT"/Sources/PageArchiveCLI/*.swift -o "$TASK_BUILD/shiye-check"
xcrun swiftc -O -target arm64-apple-macosx14.0 -module-cache-path "$TASK_BUILD/module-cache" -I "$TASK_BUILD" -L "$TASK_BUILD" -lPageArchiveCore -Xlinker -rpath -Xlinker @executable_path/../Frameworks "$TASK_ROOT"/Sources/PageArchiveApp/*.swift -o "$TASK_APP/Contents/MacOS/Shiye"
cp "$TASK_BUILD/libPageArchiveCore.dylib" "$TASK_APP/Contents/Frameworks/"
cp "$TASK_ROOT"/Sources/PageArchiveCore/Resources/Fonts/* "$TASK_APP/Contents/Resources/Fonts/"
cp "$TASK_ROOT/Sources/PageArchiveCore/Resources/OCR/SKILL.md" "$TASK_APP/Contents/Resources/OCR/"
cp "$TASK_ROOT/scripts/Info.plist" "$TASK_APP/Contents/Info.plist"
if [[ ! -f "$TASK_BUILD/AppIcon.icns" || "$TASK_ROOT/scripts/icon.swift" -nt "$TASK_BUILD/AppIcon.icns" ]]; then
  xcrun swiftc -O -target arm64-apple-macosx14.0 -module-cache-path "$TASK_BUILD/module-cache" "$TASK_ROOT/scripts/icon.swift" -o "$TASK_BUILD/icon-maker"
  "$TASK_BUILD/icon-maker" "$TASK_BUILD/AppIcon.iconset"
fi
cp "$TASK_BUILD/AppIcon.icns" "$TASK_APP/Contents/Resources/"
if [[ -f "$TASK_ROOT/docs/使用说明.txt" ]]; then cp "$TASK_ROOT/docs/使用说明.txt" "$TASK_APP/Contents/Resources/"; fi
xattr -cr "$TASK_APP"
codesign --force --sign - "$TASK_APP/Contents/Frameworks/libPageArchiveCore.dylib"
codesign --force --sign - "$TASK_APP"
codesign --verify --deep --strict "$TASK_APP"
printf '%s\n' "$TASK_APP" > "$TASK_BUILD/staged-app-path.txt"
if [[ -d "$TASK_RELEASE/拾页.app" ]]; then rm -rf "$TASK_RELEASE/拾页.app"; fi
ditto --norsrc "$TASK_APP" "$TASK_RELEASE/拾页.app"
xattr -dr com.apple.FinderInfo "$TASK_RELEASE/拾页.app" 2>/dev/null || true
codesign --verify --deep --strict "$TASK_RELEASE/拾页.app"
printf '%s\n' "$TASK_RELEASE/拾页.app"
