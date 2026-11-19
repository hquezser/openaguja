#!/usr/bin/env bash
# Garde-fou de publication OpenAguja.
#
# Échoue (code 1) si des informations privées apparaissent dans ce qui
# serait publié : fichiers suivis ou non suivis non ignorés, noms de
# fichiers sensibles, ou historique des commits (auteurs/créateurs).
#
# Le dépôt public ne doit contenir ni l'infrastructure personnelle, ni
# l'email professionnel, ni les routines/domotique privées. Les motifs
# ci-dessous sont volontairement précis : « montre » seul est un mot
# français courant, « montre- » est le préfixe des routines privées.
#
# Usage : scripts/public-check.sh [plage-git]   (défaut : tout HEAD)
# Exemple pour ne vérifier que les commits depuis main :
#   scripts/public-check.sh origin/main..HEAD
set -uo pipefail
cd "$(dirname "$0")/.."

RANGE="${1:-HEAD}"
status=0

note() { printf '  %s\n' "$*"; }
fail() { printf 'ÉCHEC : %s\n' "$*"; status=1; }

# ---------------------------------------------------------------------
# 1. Motifs interdits dans le contenu des fichiers
# ---------------------------------------------------------------------
echo "== contenu des fichiers (motifs interdits) =="

# motif|flags grep — -i seulement quand la casse importe peu.
patterns=(
    'trainme'                 # domaine / email professionnel
    'quezada'                 # nom de famille (email pro)
    'nohost'                  # domaine personnel hougo.nohost.me — sauf email de contact publique (public_literals)
    'FBRA9G94UF'              # Team ID Apple personnel
    'MacBook-Pro-de-Hugo'     # hostname personnel
    'casita|-i'               # projet domotique privé
    'superwhisper'            # outil privé (mode Nomade)
    'shutters'                # commandes volets privées
    'zetime-firmware'         # dépôt firmware privé
    'zetime-ble'              # ancien nom du dépôt privé
    'openaguja-personal'      # overlay privé
    'montre-'                 # préfixe des routines privées
    'gohu'                    # utilisateur SSH du VPS
    'netlib\.re'              # domaine d'infrastructure
    'kimsufi'                 # hébergeur du VPS
    'yunohost'                # instance auto-hébergée
)

# Chaînes explicitement publiques (ex. email de contact projet) :
# retirées du contenu avant recherche des motifs — le reste du domaine
# reste banni. Expressions sed BRE, une par élément.
public_literals=(
    'dev@hougo\.nohost\.me'
)
public_sed=()
for lit in "${public_literals[@]}"; do
    public_sed+=(-e "s/${lit}//g")
done

# Le script lui-même contient les motifs — il est exclu du scan.
files=$( { git ls-files; git ls-files -o --exclude-standard; } \
    | grep -v -x 'scripts/public-check.sh' | sort -u )
if [[ -z "$files" ]]; then
    note "aucun fichier"
else
    for entry in "${patterns[@]}"; do
        pattern="${entry%%|*}"
        flags="${entry#*|}"
        [[ "$flags" == "$entry" ]] && flags=""
        hits=$(printf '%s\n' "$files" | xargs grep -l -I -E $flags -e "$pattern" 2>/dev/null || true)
        # Ignorer les fichiers dont les seules occurrences sont des
        # chaînes explicitement publiques.
        if [[ -n "$hits" && ${#public_sed[@]} -gt 0 ]]; then
            kept=""
            while IFS= read -r hit; do
                [[ -z "$hit" ]] && continue
                if sed "${public_sed[@]}" "$hit" | grep -q -I -E $flags -e "$pattern"; then
                    kept+="$hit"$'\n'
                fi
            done <<< "$hits"
            hits="${kept%$'\n'}"
        fi
        if [[ -n "$hits" ]]; then
            fail "motif « $pattern » trouvé dans :"
            printf '%s\n' "$hits" | sed 's/^/    /'
        fi
    done
    note "scan terminé ($(printf '%s\n' "$files" | wc -l | tr -d ' ') fichiers)"
fi

# ---------------------------------------------------------------------
# 2. Noms de fichiers qui ne doivent jamais être publiés
# ---------------------------------------------------------------------
echo "== noms de fichiers sensibles =="

sensitive_re='(^|/)(recovery|RECOVERY\.md|AGENTS\.local\.md|Local\.xcconfig|\.env[^/]*|.*\.(pem|key|p12|pfx|mobileprovision|keystore)|id_rsa[^/]*)$'
hits=$(printf '%s\n' "$files" | grep -E "$sensitive_re" || true)
if [[ -n "$hits" ]]; then
    fail "fichier(s) sensible(s) suivi(s) ou non ignoré(s) :"
    printf '%s\n' "$hits" | sed 's/^/    /'
else
    note "aucun"
fi

# ---------------------------------------------------------------------
# 3. Historique git : auteurs et créateurs de commits
# ---------------------------------------------------------------------
echo "== historique git ($RANGE) =="

if ! git rev-list -n1 "$RANGE" >/dev/null 2>&1; then
    # Plage inconnue (ex. remote absent en local) : on note et on passe.
    note "plage « $RANGE » introuvable — vérification des commits ignorée"
else
    emails=$(git log --format='%ae%n%ce' "$RANGE" 2>/dev/null | sort -u || true)
    if [[ -z "$emails" ]]; then
        note "aucun commit dans la plage"
    else
        # Emails professionnels ou personnels identifiants.
        bad=$(printf '%s\n' "$emails" | grep -E -i 'trainme|quezada|nohost|gmail|hotmail|outlook|protonmail' || true)
        if [[ -n "$bad" ]]; then
            fail "email(s) d'auteur/créateur à remplacer par l'identité noreply :"
            printf '%s\n' "$bad" | sed 's/^/    /'
        fi
        # Tout email qui n'est pas une adresse noreply GitHub est
        # suspect dans ce dépôt (auteur unique « Hougo »).
        non_noreply=$(printf '%s\n' "$emails" \
            | grep -v -E '(@users\.noreply\.github\.com|^noreply@github\.com)$' || true)
        if [[ -n "$non_noreply" ]]; then
            fail "email(s) non-noreply GitHub dans l'historique :"
            printf '%s\n' "$non_noreply" | sed 's/^/    /'
            note "configurer : git config user.email \"15942149+hquezser@users.noreply.github.com\""
        fi
        note "$(printf '%s\n' "$emails" | wc -l | tr -d ' ') email(s) vérifié(s)"
    fi
fi

# ---------------------------------------------------------------------
# 4. gitleaks (optionnel — ne fait pas échouer si absent)
# ---------------------------------------------------------------------
echo "== gitleaks =="
if command -v gitleaks >/dev/null 2>&1; then
    if gitleaks git --redact --no-banner --log-opts="$RANGE" . >/tmp/openaguja-gitleaks.log 2>&1; then
        note "aucun secret détecté"
    else
        fail "gitleaks a trouvé des secrets potentiels :"
        sed 's/^/    /' /tmp/openaguja-gitleaks.log | head -30
    fi
else
    note "gitleaks absent — scan de motifs ci-dessus uniquement"
fi

echo
if [[ $status -eq 0 ]]; then
    echo "public-check OK"
else
    echo "public-check : ÉCHECS ci-dessus — ne pas publier en l'état"
fi
exit $status
