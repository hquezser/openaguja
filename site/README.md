# OpenAguja — site

Site vitrine du projet, en français et en anglais : accueil,
fonctionnalités, guide d’installation, notes protocole, blog, FAQ et
crédits. Design sombre généré avec Lovable, contenu et déploiement
gérés dans ce dépôt.

## Build

```sh
npm install
npm run build        # → .output/public (HTML statique prerenderé)
npm run dev          # serveur de dev
npm test             # vitest
```

## Déploiement

GitHub Pages du dépôt `hquezser/openaguja`, servi sous `/openaguja/` :

- `vite.config.ts` fixe `base: "/openaguja/"` et active le prerender
  TanStack Start (`pages[].prerender.crawlLinks`) — chaque route devient
  un `index.html` statique, les slugs de blog sont découverts en crawlant
  les liens.
- `.github/workflows/pages.yml` build `site/` et déploie
  `.output/public` via l’action officielle `deploy-pages`.

## Contenu

Site bilingue FR/EN :

- `src/data/content.fr.ts` / `content.en.ts` — tout le contenu
  éditorial (pages, articles de blog, FAQ) pour chaque locale.
- `src/data/types.ts` — types partagés (`Article`, sections, pages…).
- `src/data/i18n.ts` — accès au contenu de la locale courante.
- Routes FR à la racine (`/`, `/fonctionnalites`, `/installation`,
  `/protocole`, `/blog`, `/faq`, `/credits`) ; miroir anglais sous
  `/en/*` (`/en`, `/en/features`, `/en/install`, `/en/protocol`,
  `/en/blog`, `/en/faq`, `/en/credits`).

**Articles de blog** : ajouter une entrée dans `articles` des DEUX
fichiers `content.fr.ts` et `content.en.ts`, **au même index** — le
sélecteur de langue traduit les slugs par position. Le prerender
découvre les nouvelles pages tout seul.

Sections d’article : `title` + `text` (mini-markdown : `` `code` ``,
`**gras**`, `[lien](url)`) + `code` optionnel pour un bloc de code.

## Synchronisation Lovable

Ce dossier est une copie de travail du projet Lovable
`openaguja-gh-pages` (resté privé). Les améliorations de design se font
dans Lovable puis sont reportées ici ; les contenus factuels (prix,
liens, état du projet) sont maintenus dans ce dépôt.
