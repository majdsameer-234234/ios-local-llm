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
#    The xcframeworks are restored by the Codemagic cache when the pinned
#    submodules have not changed, so this step is normally a no-op. Building
#    llama.cpp + whisper.cpp from scratch is what made every build ~20 minutes.
LLAMA_XCF=ThirdParty/llama.cpp/build-apple/llama.xcframework
WHISPER_XCF=ThirdParty/whisper.cpp/build-apple/whisper.xcframework
if [[ -d "$LLAMA_XCF" && -d "$WHISPER_XCF" ]]; then
  echo "==> native frameworks restored from cache; skipping the rebuild"
else
  ./scripts/build_native_frameworks.sh
fi

# 4. project + pods
brew install xcodegen
xcodegen generate
# Podfile.lock is committed, so the spec repo update is pure cost.
pod install

# 4b. Metal toolchain: mlx-swift shader compile fails without it.
#     This line was lost when 6f05e63 regenerated the script - the
#     11:46 UTC build died on "cannot execute tool 'metal' due to
#     missing Metal Toolchain". Keep it.
xcodebuild -downloadComponent MetalToolchain || echo "Metal toolchain already installed"

# 5. archive unsigned (no Apple account needed)
set -o pipefail
# Podfile pins OnDeviceLAS.xcodeproj -> pod install regenerates
# OnDeviceLAS.xcworkspace. The checked-in IOSLocalLLM.xcworkspace is the
# stale pre-rename one and has no OnDeviceLAS scheme:
# "workspace named IOSLocalLLM does not contain scheme OnDeviceLAS"
# killed the 14-minute build at 10:28 UTC on 2026-11-07.
xcodebuild \
  -workspace OnDeviceLAS.xcworkspace \
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
