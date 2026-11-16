#!/usr/bin/env bash
# Libère l'espace disque régénérable du projet :
# - worktrees .claude/worktrees mergés et propres (chacun contient son
#   propre target/ — plusieurs Go)
# - target/ (cache cargo, reconstruit par le prochain build)
# - DerivedData de ce projet (cache Xcode, reconstruit)
# - ios/OpenAgujaCore (package cargo-swift, régénéré par build-ios.sh)
# Ne touche pas les données privées non suivies (gitignored).
set -euo pipefail
cd "$(dirname "$0")/.."

for wt in .claude/worktrees/*/; do
    [ -d "$wt" ] || continue
    if git -C "$wt" status --porcelain | grep -q .; then
        echo "skip $wt (non commité)"
        continue
    fi
    if [ "$(git -C "$wt" rev-parse HEAD)" != "$(git rev-parse HEAD)" ]; then
        echo "skip $wt (commit différent de master)"
        continue
    fi
    git worktree remove --force "$wt" && echo "worktree $wt supprimé"
done

rm -rf ~/Library/Developer/Xcode/DerivedData/OpenAguja-* ios/OpenAgujaCore
cargo clean

du -sh .
