#!/usr/bin/env bash
# Construit le package Swift OpenAgujaCore (cargo-swift) puis l'app iOS.
# `--rust-only` ne compile que les .a Rust pour iOS — marche sans Xcode.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "${1:-}" == "--rust-only" ]]; then
    cargo build -p openaguja-ffi --release --target aarch64-apple-ios
    cargo build -p openaguja-ffi --release --target aarch64-apple-ios-sim
    exit 0
fi

if ! xcodebuild -version >/dev/null 2>&1; then
    echo "xcodebuild indisponible : il faut Xcode complet" >&2
    echo "  sudo xcode-select -s /Applications/Xcode.app" >&2
    exit 1
fi

rustup target list --installed | grep -qx aarch64-apple-ios \
    || rustup target add aarch64-apple-ios
rustup target list --installed | grep -qx aarch64-apple-ios-sim \
    || rustup target add aarch64-apple-ios-sim

# cargo-swift écrit ./OpenAgujaCore dans le répertoire courant (ici openaguja-ffi) ;
# on le déplace à l'emplacement attendu par project.yml.
(cd openaguja-ffi && cargo swift package -p ios -n OpenAgujaCore -r -y --lib-type static)
rm -rf ios/OpenAgujaCore
mv openaguja-ffi/OpenAgujaCore ios/OpenAgujaCore

if command -v xcodegen >/dev/null 2>&1; then
    (cd ios && xcodegen generate)
else
    echo "xcodegen absent (brew install xcodegen) — projet Xcode non régénéré" >&2
fi

xcodebuild -project ios/OpenAguja.xcodeproj -scheme OpenAguja \
    -destination 'generic/platform=iOS' -configuration Debug \
    CODE_SIGNING_ALLOWED=NO build
