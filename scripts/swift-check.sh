#!/usr/bin/env bash
# Vérifie le code Swift sans Xcode :
#  1. typecheck des fichiers non-UI (BLE, ponts webhook/daemon, trousseau,
#     profil) compilés avec les bindings UniFFI dans le même module —
#     App/AppDelegate/vues exclus : UIKit et modifiers iOS n'existent pas
#     côté macOS.
#  2. smoke tests compilés et exécutés : protocole BLE contre
#     libopenaguja_ffi.a, et modèle de profil (sans FFI).
set -euo pipefail
cd "$(dirname "$0")/.."

BINDINGS=target/uniffi-swift
TARGET=arm64-apple-macos13

cargo build -p openaguja-ffi --release
cargo run -p openaguja-ffi --features bindgen --bin uniffi-bindgen -- \
    generate --library target/release/libopenaguja_ffi.a \
    --language swift --out-dir "$BINDINGS"

echo "== typecheck (macOS arm64, fichiers non-UI) =="
swiftc -typecheck -swift-version 5 \
    -target "$TARGET" \
    -Xcc -fmodule-map-file="$BINDINGS/openaguja_ffiFFI.modulemap" \
    -I "$BINDINGS" \
    "$BINDINGS/openaguja_ffi.swift" \
    ios/OpenAguja/ZeTimeBluetoothManager.swift \
    ios/OpenAguja/WatchAPI.swift \
    ios/OpenAguja/MemoryDump.swift \
    ios/OpenAguja/LogStore.swift \
    ios/OpenAguja/WatchSettingsModel.swift \
    ios/OpenAguja/EnergyProfile.swift \
    ios/OpenAguja/IntegrationConfig.swift \
    ios/OpenAguja/ActionRouter.swift \
    ios/OpenAguja/Profile.swift \
    ios/OpenAguja/NowPlaying.swift \
    ios/OpenAguja/WeatherService.swift \
    ios/OpenAguja/ActivityStore.swift \
    ios/OpenAguja/WebhookBridge.swift \
    ios/OpenAguja/MacDaemonBridge.swift \
    ios/OpenAguja/TelemetryUploader.swift \
    ios/OpenAguja/TelemetryHistory.swift \
    ios/OpenAguja/TelemetryService.swift \
    ios/OpenAguja/HeartRateService.swift \
    ios/OpenAguja/Keychain.swift

echo "== smoke test (protocole) =="
swiftc -swift-version 5 \
    -target "$TARGET" \
    -Xcc -fmodule-map-file="$BINDINGS/openaguja_ffiFFI.modulemap" \
    -I "$BINDINGS" \
    "$BINDINGS/openaguja_ffi.swift" \
    scripts/swift-smoke/main.swift \
    target/release/libopenaguja_ffi.a \
    -o /tmp/openaguja-swift-smoke
/tmp/openaguja-swift-smoke

echo "== smoke test (profil) =="
swiftc -swift-version 5 \
    -target "$TARGET" \
    ios/OpenAguja/IntegrationConfig.swift \
    ios/OpenAguja/ActionRouter.swift \
    ios/OpenAguja/Profile.swift \
    ios/OpenAguja/MacDaemonBridge.swift \
    ios/OpenAguja/LogStore.swift \
    ios/OpenAguja/Keychain.swift \
    "$PWD/scripts/swift-smoke/profile_main.swift" \
    -o /tmp/openaguja-profile-smoke
/tmp/openaguja-profile-smoke
echo "swift-check OK"
