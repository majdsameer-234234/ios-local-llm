set -euo pipefail
# OnDevice LAS - build an unsigned IPA on Codemagic's macOS runner.
# The repo cloned here is the public upstream; everything below adds the fork.

git submodule update --init --recursive

# 1. llama.cpp b10830 = first release with Spark-X2.6 (spark2_5) support
cd ThirdParty/llama.cpp
git fetch --depth 1 origin tag b10830
git checkout -q b10830
cd ../..

# 2. fork changes: context setting, /v1/system telemetry, iOS-only build fix,
#    GGUF header walk, EOG stop - ALL COMMITTED to the fork as of d939f09.
#    The old base64 patch payload here re-applied hunks that are already in
#    the clone ("patch does not apply" -> build dead in 60s, 2026-11-07), and
#    its last regeneration was UTF-16, which git apply cannot read at all.
#    Nothing is left to patch; if the fork ever falls behind its own patch
#    again, regenerate from `git diff <base> main -- <files>` in UTF-8 only.

# 3. native frameworks (iOS slices only)
./scripts/build_native_frameworks.sh

# 4. project + pods
brew install xcodegen
xcodegen generate
pod install --repo-update

# 5. archive unsigned (no Apple account needed)
set -o pipefail
xcodebuild \
  -workspace IOSLocalLLM.xcworkspace \
  -scheme OnDeviceLAS \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -archivePath build/OnDeviceLAS.xcarchive \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  archive

# 6. package
mkdir -p build/ipa/Payload
cp -R build/OnDeviceLAS.xcarchive/Products/Applications/OnDeviceLAS.app build/ipa/Payload/
cd build/ipa
/usr/bin/zip -qry ../OnDeviceLAS-unsigned.ipa Payload
cd ../..
ls -lh build/OnDeviceLAS-unsigned.ipa
