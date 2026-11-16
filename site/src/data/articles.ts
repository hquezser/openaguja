export type Article = { slug: string; title: string; date: string; tags: string[]; readingTime: number; summary: string; content: { title: string; text: string; code?: string }[] };

export const articles: Article[] = [
  {
    slug: 'protocole-en-bref',
    title: 'Le protocole ZeTime en 5 minutes',
    date: '2026-11-02',
    tags: ['Protocole', 'BLE'],
    readingTime: 6,
    summary: 'Un service GATT, quatre caractéristiques, une enveloppe de trame et quelques dizaines d’opcodes : l’essentiel de ce qu’il faut savoir avant de toucher à une montre ZeTime.',
    content: [
      { title: 'Une seule service, quatre portes', text: 'En mode normal, la montre expose le service 00006006-0000-1000-8000-00805f9b34fb avec quatre caractéristiques : 0x8001 pour écrire les commandes, 0x8002 pour les accusés, 0x8003 pour les réponses, et 0x8004 pour les événements initiés par la montre (musique, appel, chercher le téléphone, réponses rapides). Pas de service Nordic DFU : la mise à jour passe par un déclencheur propriétaire.' },
      { title: 'L’enveloppe 6F…8F', text: 'Chaque message commence par 6F, se termine par 8F, et transporte un octet d’opcode, un sens (71 = envoi, 70 = requête), une longueur et la charge utile. Il n’y a pas de checksum : les trames de plus de 20 octets sont découpées en chunks et réassemblées par la montre.' },
      { title: 'Les pièges', text: 'Certains événements bloquent la montre jusqu’à réception d’un accusé générique sur 0x8003. D’autres opcodes sont carrément dangereux — effacement de flash, coupure, réécriture de régions. Toute la liste est dans docs/SAFETY.md du dépôt, à lire avant le premier envoi.' },
    ],
  },
  {
    slug: 'retoucher-les-images',
    title: 'Retoucher les images de la montre sans la cracker',
    date: '2026-10-30',
    tags: ['Firmware', 'Lab'],
    readingTime: 7,
    summary: 'Les icônes du menu et le logo de démarrage vivent dans des partitions d’images BGR565. Voici comment les outils d’openaguja-lab les réécrivent proprement, en ne touchant que la zone visée.',
    content: [
      { title: 'Des pixels, pas du code', text: 'Les menus de la montre sont des images brutes dans les partitions Picture_*.bin : 72×72 pixels en BGR565 pour les icônes, 18 frames de 156×34 pour le logo de boot. Pas de compression exotique, pas de conteneur : on peut les réécrire octet par octet.' },
      { title: 'Vérifier avant de flasher', text: 'Chaque outil compare l’image modifiée à l’originale et refuse d’écrire si un octet hors de la zone cible a changé. Le flash se fait ensuite par tranches de 64 Ko alignées via le DFU propriétaire — jamais l’image entière d’un coup.' },
      { title: 'Le lab, pas le firmware', text: 'openaguja-lab fournit les outils mais aucun firmware : vous partez de vos propres dumps, vous assumez les risques, et personne ne vous distribute du code propriétaire. C’est le deal.' },
    ],
  },
  {
    slug: 'donnees-sante',
    title: 'Vos données de santé, votre choix',
    date: '2026-11-08',
    tags: ['Vie privée', 'Télémétrie'],
    readingTime: 5,
    summary: 'Pas, sommeil et fréquence cardiaque ne quittent la montre que si vous le décidez : synchronisation en local ou envoi vers votre propre endpoint webhook.',
    content: [
      { title: 'Rien ne part tout seul', text: 'La montre ne parle qu’en Bluetooth LE à l’iPhone qui la pilote. L’app OpenAguja lit les enregistrements d’activité pendant les synchros et les garde en mémoire — aucun serveur OpenAguja n’existe pour les recevoir.' },
      { title: 'Un endpoint, pas un cloud', text: 'Si vous configurez une URL de télémétrie, les événements partent en JSON vers CE endpoint, avec votre jeton. Un Raspberry Pi sur le LAN, un VPS personnel, un Home Assistant : c’est vous qui choisissez la destination et ce qu’elle en fait.' },
      { title: 'La file hors-ligne', text: 'Sans réseau, les événements de télémétrie sont mis en file localement et repartent à la prochaine occasion. Les actions immédiates de la montre, elles, ne sont jamais rejouées — un « play » dix minutes plus tard n’aurait pas de sens.' },
    ],
  },
];
