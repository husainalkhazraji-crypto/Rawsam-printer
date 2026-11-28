#!/bin/bash
# كل خطوات البناء هنا، حتى ملف الـ workflow يبقى ثابت.
set -euo pipefail

VERSION="0.2.${RUN_NUMBER:-0}"
IPA="RawsamPrinter-v$VERSION.ipa"

echo "== اختبارات أوامر الطابعة"
swiftc App/PrinterProtocol.swift Tests/main.swift -o /tmp/protocol-tests
/tmp/protocol-tests

echo "== الأيقونة واللوكو"
python3 -m venv /tmp/art
/tmp/art/bin/pip install -q pillow
/tmp/art/bin/python tools/make_art.py

echo "== مشروع Xcode"
brew install xcodegen
sed -i '' "s/MARKETING_VERSION: \"0.2.0\"/MARKETING_VERSION: \"$VERSION\"/; s/CURRENT_PROJECT_VERSION: \"1\"/CURRENT_PROJECT_VERSION: \"${RUN_NUMBER:-1}\"/" project.yml
xcodegen generate

echo "== البناء بدون توقيع"
xcodebuild -project RawsamPrinter.xcodeproj -scheme RawsamPrinter -configuration Release -sdk iphoneos \
  -destination 'generic/platform=iOS' -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build 2>&1 \
  | grep -E "error:|warning: .*\.swift|BUILD (SUCCEEDED|FAILED)" | grep -v "appintents" | head -80 || true
# لازم يكون البناء نجح فعلاً والتطبيق بيه الملف التنفيذي.
test -f build/Build/Products/Release-iphoneos/RawsamPrinter.app/RawsamPrinter || { echo "البناء فشل"; exit 1; }

echo "== تجهيز ملف IPA"
mkdir -p Payload
cp -R build/Build/Products/Release-iphoneos/RawsamPrinter.app Payload/
# أي اسم ملف غير إنگليزي داخل التطبيق يخرّب التثبيت بأدوات التوقيع.
bad=$(cd Payload && find . -print | LC_ALL=C grep '[^ -~]' || true)
if [ -n "$bad" ]; then echo "أسماء ملفات غير إنگليزية داخل التطبيق:"; echo "$bad"; exit 1; fi
ditto -c -k --sequesterRsrc --keepParent Payload "$IPA"
ls -la "$IPA"

if [ -n "${GH_TOKEN:-}" ]; then
  echo "== نشر الإصدار"
  gh release create "v$VERSION" "$IPA" --title "Rawsam printer $VERSION" \
    --notes "ملف آيفون غير موقّع. وقّعه وثبّته بحساب المطور."
fi
