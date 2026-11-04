#!/bin/sh
# Puts llama.cpp's prebuilt iPhone framework in ios/Vendor/llama.framework (used only for real-iPhone builds).
# Pinned release, checked against the SHA-256 GitHub publishes for it. llama.cpp is MIT-licensed.
set -e
TAG=b11803
SHA=c2357c2f0f2073740be3c67f968fcc137fe540037233759f2e89728880fe2abf
cd "$(dirname "$0")"
TMP=$(mktemp -d)
curl -sSL -o "$TMP/llama.zip" "https://github.com/ggml-org/llama.cpp/releases/download/$TAG/llama-$TAG-xcframework.zip"
echo "$SHA  $TMP/llama.zip" | shasum -a 256 -c -
unzip -q "$TMP/llama.zip" -d "$TMP"
rm -rf llama.framework
cp -R "$TMP/build-apple/llama.xcframework/ios-arm64/llama.framework" .
curl -sSL -o LICENSE-llama.cpp.txt "https://raw.githubusercontent.com/ggml-org/llama.cpp/$TAG/LICENSE"
echo "$TAG" > llama.framework.version
rm -rf "$TMP"
echo "llama.cpp $TAG ready in $(pwd)/llama.framework"
