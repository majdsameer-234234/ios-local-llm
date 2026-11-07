#!/usr/bin/env bash

# Reproducibly build the native llama.cpp and whisper.cpp XCFrameworks from
# pinned submodules. Generated frameworks remain ignored by Git.

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
include_catalyst=0

if [[ "${1:-}" == "--with-catalyst" ]]; then
  include_catalyst=1
elif [[ $# -gt 0 ]]; then
  echo "usage: $0 [--with-catalyst]" >&2
  exit 64
fi

git -C "$repository_root" submodule update --init --recursive

llama_root="${repository_root}/ThirdParty/llama.cpp"
llama_patch="${repository_root}/Patches/llama.cpp-ios-only-xcframework.patch"

# Upstream added explicit target selection (BUILDS=("$@")), so a newer pin
# needs no local patch. The tracked patch is kept for older pins only.
if grep -q 'BUILDS=("\$@")' "${llama_root}/build-xcframework.sh"; then
  echo "==> llama.cpp supports explicit iOS targets (no patch needed)"
  LLAMA_IOS_BUILD=("./build-xcframework.sh" "ios-sim" "ios-device")
elif grep -q 'IOS_ONLY:-0' "${llama_root}/build-xcframework.sh"; then
  echo "==> llama.cpp iOS-only build support is already present"
  LLAMA_IOS_BUILD=("env" "IOS_ONLY=1" "./build-xcframework.sh")
elif git -C "$llama_root" apply --check "$llama_patch" >/dev/null 2>&1; then
  echo "==> Applying the tracked llama.cpp iOS-only build patch"
  git -C "$llama_root" apply "$llama_patch"
  LLAMA_IOS_BUILD=("env" "IOS_ONLY=1" "./build-xcframework.sh")
else
  echo "error: the llama.cpp build patch does not match the pinned submodule" >&2
  echo "       restore or inspect ThirdParty/llama.cpp/build-xcframework.sh" >&2
  exit 1
fi

# A restored build cache leaves these in place. Rebuilding them is the single
# most expensive step of a CI run (llama.cpp plus whisper.cpp for two Apple
# slices), so an existing framework is reused instead of treated as an error.
whisper_root="${repository_root}/ThirdParty/whisper.cpp"

if [[ -e "${llama_root}/build-apple/llama.xcframework" ]]; then
  echo "==> llama.xcframework already present; skipping the rebuild"
else
  echo "==> Building llama.cpp iOS XCFramework"
  (cd "$llama_root" && IOS_ONLY=1 ./build-xcframework.sh)
fi

if [[ -e "${whisper_root}/build-apple/whisper.xcframework" ]]; then
  echo "==> whisper.xcframework already present; skipping the rebuild"
else
  echo "==> Building whisper.cpp iOS XCFramework"
  "${repository_root}/scripts/native/build_whisper_ios.sh"
fi

if [[ "$include_catalyst" == 1 ]]; then
  "${repository_root}/scripts/native/build_catalyst_slice.sh" llama
  "${repository_root}/scripts/native/build_catalyst_slice.sh" whisper
fi

echo "==> Native frameworks are ready"
