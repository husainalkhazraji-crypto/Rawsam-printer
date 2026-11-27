#!/bin/bash
# كل خطوات البناء هنا، حتى ملف الـ workflow يبقى ثابت وما يحتاج تعديل.
set -euo pipefail

echo "== اختبارات أوامر الطابعة"
swiftc App/PrinterProtocol.swift Tests/main.swift -o /tmp/protocol-tests
/tmp/protocol-tests

echo "== الأيقونة والتصاميم التجريبية"
python3 -m venv /tmp/art
/tmp/art/bin/pip install -q pillow
/tmp/art/bin/python tools/make_art.py

echo "== مشروع Xcode"
brew install xcodegen
VERSION="0.1.${RUN_NUMBER:-0}"
sed -i '' "s/MARKETING_VERSION: \"0.1.0\"/MARKETING_VERSION: \"$VERSION\"/; s/CURRENT_PROJECT_VERSION: \"1\"/CURRENT_PROJECT_VERSION: \"${RUN_NUMBER:-1}\"/" project.yml
xcodegen generate

echo "== البناء بدون توقيع"
xcodebuild -project Washm.xcodeproj -scheme Washm -configuration Release -sdk iphoneos \
  -destination 'generic/platform=iOS' -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build | tail -80

echo "== تجهيز ملف IPA"
mkdir -p Payload
cp -R build/Build/Products/Release-iphoneos/Washm.app Payload/
# أي اسم ملف غير إنگليزي داخل التطبيق يخرّب التثبيت بأدوات التوقيع.
bad=$(cd Payload && find . -print | LC_ALL=C grep '[^ -~]' || true)
if [ -n "$bad" ]; then echo "أسماء ملفات غير إنگليزية داخل التطبيق:"; echo "$bad"; exit 1; fi
ditto -c -k --sequesterRsrc --keepParent Payload Washm-iOS-unsigned.ipa
ls -la Washm-iOS-unsigned.ipa

if [ -n "${GH_TOKEN:-}" ]; then
  echo "== نشر الإصدار"
  gh release create "v$VERSION" Washm-iOS-unsigned.ipa --title "وشم $VERSION" \
    --notes "ملف آيفون غير موقّع. ثبّته بـ Sideloadly أو AltStore."
fi
