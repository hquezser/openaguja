# OpenAguja — site

Site vitrine du projet, en français : accueil, fonctionnalités, guide
d’installation, notes protocole, blog, FAQ et crédits. Design sombre
généré avec Lovable, contenu et déploiement gérés dans ce dépôt.

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

Les textes éditoriaux vivent dans `src/data/` (`project.ts`,
`articles.ts`, `faq.ts`) ; les gabarits de page dans `src/routes/` et
`src/components/zetime/documentation.tsx`. Pour ajouter un article :
une entrée dans `articles.ts`, le prerender le découvre tout seul.

## Synchronisation Lovable

Ce dossier est une copie de travail du projet Lovable
`openaguja-gh-pages` (resté privé). Les améliorations de design se font
dans Lovable puis sont reportées ici ; les contenus factuels (prix,
liens, état du projet) sont maintenus dans ce dépôt.
