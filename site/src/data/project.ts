export const repoUrl = 'https://github.com/hquezser/openaguja';
export const labUrl = 'https://github.com/hquezser/openaguja-lab';

export const navigation = [
  { to: '/', label: 'Accueil' }, { to: '/fonctionnalites', label: 'Fonctionnalités' },
  { to: '/installation', label: 'Installation' }, { to: '/protocole', label: 'Protocole' },
  { to: '/blog', label: 'Blog' }, { to: '/faq', label: 'FAQ' }, { to: '/credits', label: 'Crédits & Licence' },
] as const;

export const features = [
  { icon: 'bluetooth', title: 'Connexion Bluetooth LE', text: 'Une communication directe avec la montre, sans détour par le cloud ni compte.', tag: 'CONNECTIVITÉ' },
  { icon: 'bell', title: 'Notifications et actions', text: 'Messages, appels et actions de la couronne routées vers vos propres outils : webhook, Mac, Shortcuts.', tag: 'AU QUOTIDIEN' },
  { icon: 'code', title: 'Un protocole ouvert', text: 'Le protocole BLE est documenté dans le dépôt : opcodes, trames et pièges à éviter.', tag: 'REVERSE ENGINEERING' },
];

// État réel du projet, à maintenir au fil des releases.
export const homeStatus = [
  { label: 'Protocole BLE documenté (docs/PROTOCOL.md)', done: true },
  { label: 'App compagnon iOS (SideStore, AltStore ou Xcode)', done: true },
  { label: 'CLI + bibliothèque Rust open-source', done: true },
  { label: 'Routage webhook et télémétrie', done: true },
  { label: 'Cadrans personnalisés et mise à jour DFU', done: true },
  { label: 'Outils d’images firmware (openaguja-lab)', done: true },
  { label: 'IPA pré-signée dans les Releases', done: false, note: 'en cours' },
];

export const homeLog = [
  { date: '2026-11-16', text: 'Le site est en ligne. L’app a été validée de bout en bout sur iPhone : connexion, modes de routage, webhook et daemon macOS.' },
  { date: '2026-11-08', text: 'openaguja-lab publié : outils pour retoucher les images de la montre (icônes du menu, logo de démarrage) sans firmware fourni.' },
  { date: '2026-11-02', text: 'Protocole bouclé : alarmes, calendrier, réponses rapides, réglages simples et calibration des aiguilles documentés et implémentés.' },
  { date: '2026-10-30', text: 'Premières icônes de menu personnalisées flashées et validées sur la montre — les outils sont dans openaguja-lab.' },
];
