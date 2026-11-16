#!/usr/bin/env bash
# Réinstalle OpenAguja sur l'iPhone appairé : le profil de provisioning
# des certificats de développement expire après 7 jours — un rebuild signé
# quotidien maintient l'app installable en permanence.
#
# Planifié par launchd (modèle : contrib/launchd/deploy.plist.template) :
#   launchctl load ~/Library/LaunchAgents/<label>.plist
# Journal : celui indiqué par __LOG__ dans le modèle contrib/launchd/deploy.plist.template
#
# Prérequis : iPhone appairé (Xcode → Devices → « Connect via network »
# pour le sans-fil), compte de signature configuré dans Xcode et
# ios/Config/Local.xcconfig renseigné (voir Local.xcconfig.example).
# Sortie propre (code 0) si aucun iPhone n'est joignable.
set -euo pipefail
cd "$(dirname "$0")/.."

log() { echo "[deploy $(date '+%F %T')] $*"; }

# 1. iPhone appairé joignable — UDID surchargeable via OPENAGUJA_DEVICE_UDID
#    (repli : ZETIME_IPHONE_UDID, ancien nom de variable).
DEVICE_UDID="${OPENAGUJA_DEVICE_UDID:-${ZETIME_IPHONE_UDID:-}}"
if [[ -z "$DEVICE_UDID" ]]; then
    DEVICES_JSON=$(mktemp -t openaguja-devices)
    trap 'rm -f "$DEVICES_JSON"' EXIT
    xcrun devicectl list devices --json-output "$DEVICES_JSON" >/dev/null 2>&1 || true
    DEVICE_UDID=$(python3 - "$DEVICES_JSON" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
for d in data.get("result", {}).get("devices", []):
    name = d.get("deviceProperties", {}).get("name", "")
    state = d.get("connectionProperties", {}).get("pairingState", "")
    if "iphone" in name.lower() and state == "paired":
        print(d.get("hardwareProperties", {}).get("udid", ""))
        break
PY
)
fi

if [[ -z "$DEVICE_UDID" ]]; then
    log "aucun iPhone appairé joignable — rien à faire"
    exit 0
fi
log "iPhone cible : $DEVICE_UDID"

# 2. Projet Xcode à jour (ramasse les fichiers sources ajoutés/supprimés).
(cd ios && xcodegen generate >/dev/null)

# 3. Build incrémental signé pour l'appareil — -allowProvisioningUpdates
#    demande à Xcode de renouveler le profil quand il approche de sa fin.
xcodebuild -project ios/OpenAguja.xcodeproj -scheme OpenAguja \
    -destination "id=$DEVICE_UDID" -configuration Debug \
    -allowProvisioningUpdates build >/tmp/openaguja-deploy-build.log 2>&1 || {
        log "BUILD FAILED — voir /tmp/openaguja-deploy-build.log"
        exit 1
    }

APP_PATH=$(ls -dt "$HOME"/Library/Developer/Xcode/DerivedData/OpenAguja-*/Build/Products/Debug-iphoneos/OpenAguja.app 2>/dev/null | head -1)
if [[ -z "${APP_PATH:-}" ]]; then
    log "BUILD FAILED — .app introuvable"
    exit 1
fi

# 4. Installation (idempotente : met à jour l'app existante).
xcrun devicectl device install app --device "$DEVICE_UDID" "$APP_PATH" || {
    log "INSTALL FAILED — iPhone déverrouillé et joignable requis"
    exit 1
}

log "OK — $(basename "$(dirname "$APP_PATH")") installé"
