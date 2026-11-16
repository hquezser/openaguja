#!/usr/bin/env bash
# Active les hooks versionnés du dépôt (.githooks/) pour ce clone.
set -euo pipefail
cd "$(dirname "$0")/.."
git config core.hooksPath .githooks
chmod +x .githooks/pre-push scripts/public-check.sh
echo "Hooks activés : core.hooksPath = .githooks"
echo "Le pre-push exécutera scripts/public-check.sh avant chaque push."
