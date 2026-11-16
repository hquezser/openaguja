import { Link } from '@tanstack/react-router';
import { ArrowRight, Bluetooth, Bell, Code2, ShieldCheck, Radio, Watch, ChevronDown, ArrowUpRight } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { CodeBlock } from './code-block';
import { features, repoUrl, labUrl } from '@/data/project';
import { articles } from '@/data/articles';
import { faq } from '@/data/faq';

export function FeatureGrid() { const icons = [Bluetooth, Bell, Code2]; return <div className="feature-grid">{features.map((f,i) => { const Icon = icons[i] ?? Code2; return <article className="feature-card" key={f.title}><div className="flex items-center justify-between"><Icon className="size-6 text-primary"/><ArrowUpRight className="size-4 text-muted-foreground"/></div><h3 className="mt-7 text-lg font-semibold">{f.title}</h3><p className="mt-3 text-sm leading-6 text-muted-foreground">{f.text}</p><p className="mt-7 font-mono text-[10px] tracking-widest text-muted-foreground">{f.tag}</p></article>; })}</div>; }

export function ArticleGrid() { return <div className="article-grid">{articles.map((a,i) => <Link to="/blog/$slug" params={{slug:a.slug}} key={a.slug} className="article-card"><div className={`article-visual article-visual-${i}`}><span className="font-mono text-primary">{i===0 ? <Watch className="size-16"/> : i===1 ? <Radio className="size-16"/> : <Code2 className="size-16"/>}</span><span className="article-visual-label">{['HYBRID / 01','BLE / 02','OPEN SOURCE / 03'][i]}</span></div><div className="py-5"><div className="flex justify-between font-mono text-[10px] text-muted-foreground"><span>{a.tags[0]}</span><span>{a.readingTime} MIN DE LECTURE</span></div><h3 className="mt-3 text-lg font-semibold leading-7">{a.title}</h3><p className="mt-2 text-sm leading-6 text-muted-foreground">{a.summary}</p><span className="mt-5 inline-flex items-center gap-2 text-xs text-primary">Lire l’article <ArrowRight className="size-3"/></span></div></Link>)}</div>; }

export function PageIntro({ label, title, text }: { label: string; title: string; text: string }) { return <div className="page-intro"><span className="eyebrow">{label}</span><h1 className="mt-5 font-display text-4xl font-semibold md:text-5xl">{title}</h1><p className="mt-5 max-w-2xl text-base leading-8 text-muted-foreground">{text}</p></div>; }

export function DocumentationPage({ page }: { page: 'fonctionnalites'|'installation'|'protocole'|'blog'|'faq'|'credits' }) {
 return <main className="site-container document-page">{page === 'fonctionnalites' ? <>
  <PageIntro label="LES POSSIBILITÉS" title="Ce que fait OpenAguja." text="L’état réel des fonctionnalités, tel qu’il tourne sur une montre ZeTime aujourd’hui."/>
  <FeatureGrid/>
  <div className="document-prose">
   <h2>Au quotidien</h2>
   <p>Appairage direct en Bluetooth LE, heure et date synchronisées, notifications filtrées par catégorie, alarmes, rappel et réponses rapides. Les actions de la montre — musique, appel, « chercher le téléphone », SOS — sont routées vers les cibles de votre choix : un webhook, un daemon sur votre Mac, un raccourci, ou simplement l’iPhone.</p>
   <h2>Activité et santé</h2>
   <p>Pas, sommeil et fréquence cardiaque lus pendant les synchros, calendrier du mois, météo et musique synchronisés. Un mode développeur donne accès à la télémétrie brute et à l’historique.</p>
   <h2>Avancé, mais sans jailbreak</h2>
   <p>Modes de routage (bureau, sport, nomade…), profils JSON importables, journal technique, dump mémoire et outils de maintenance. Le mode développeur masque tout ça pour un usage courant.</p>
   <h2>Côté firmware</h2>
   <p>Upload de cadrans personnalisés, lecture des partitions d’images et mise à jour DFU documentée. Les outils qui retouchent les images (icônes du menu, logo de démarrage) vivent dans le dépôt séparé <a href={labUrl} target="_blank" rel="noreferrer">openaguja-lab</a> — sans firmware fourni, à vos risques et périls.</p>
   <div className="inline-flex items-center gap-3 text-primary"><ShieldCheck/>Aucun compte requis, aucun serveur OpenAguja : tout reste entre votre iPhone et votre montre.</div>
  </div>
 </> : page === 'installation' ? <>
  <PageIntro label="PREMIERS PAS" title="Installation" text="Trois chemins : l’IPA toute faite (bientôt), un sideload via SideStore/AltStore, ou le build Xcode depuis les sources."/>
  <div className="doc-columns"><aside><span className="eyebrow">SUR CETTE PAGE</span><a href="#prerequis">01 · Prérequis</a><a href="#sideStore">02 · SideStore / AltStore</a><a href="#sources">03 · Build Xcode</a><a href="#cli">04 · CLI Rust</a></aside><div className="document-prose">
   <div className="notice">Pas d’App Store : l’app est distribuée en IPA non signée, à installer avec votre propre certificat ou via SideStore.</div>
   <h2 id="prerequis">01. Les prérequis</h2>
   <p>Un iPhone sous iOS 16 ou plus, une montre ZeTime chargée et le Bluetooth activé. Pour compiler vous-même : macOS, Xcode et un Apple ID (gratuit suffit pour signer sur votre appareil). Le guide complet est dans <a href={`${repoUrl}/blob/main/docs/INSTALL.md`} target="_blank" rel="noreferrer">docs/INSTALL.md</a> du dépôt.</p>
   <h2 id="sideStore">02. SideStore ou AltStore</h2>
   <p>L’IPA pré-signée arrive dans les Releases du dépôt. En attendant, vous pouvez construire l’IPA vous-même puis l’installer via SideStore (recommandé, renouvellement automatique) ou AltStore. Une fois installée, l’app se met à jour comme n’importe quelle app sideloadée.</p>
   <h2 id="sources">03. Compiler depuis les sources</h2>
   <p>Clonez le dépôt, générez le projet Xcode avec xcodegen, renseignez votre Team ID dans <code>ios/Config/Local.xcconfig</code> (modèle fourni), puis build et run vers votre iPhone. Le bundle id par défaut est générique : changez-le si vous cohabitez avec une autre signature.</p>
   <CodeBlock label="SHELL" code={'git clone https://github.com/hquezser/openaguja.git\ncd openaguja\ncd ios && xcodegen generate\n# ouvrir OpenAguja.xcodeproj dans Xcode, choisir votre équipe'}/>
   <h2 id="cli">04. Le CLI</h2>
   <p>Le même protocole existe en ligne de commande, pratique pour un Mac toujours allumé ou un Raspberry Pi : scan, appairage, commandes, dump mémoire et DFU. Compilation Rust standard, dépendances Bluetooth via btleplug.</p>
   <CodeBlock label="SHELL" code={'cargo build --release --features cli\n./target/release/openaguja --help'}/>
   <Button asChild variant="outline"><a href={`${repoUrl}/blob/main/docs/INSTALL.md`} target="_blank" rel="noreferrer">Guide d’installation complet<ArrowRight/></a></Button>
  </div></div>
 </> : page === 'protocole' ? <>
  <PageIntro label="SOUS LE CAPOT" title="Le protocole BLE" text="Un service GATT propriétaire, des trames sans checksum et une vingtaine d’opcodes documentés — tout est dans docs/PROTOCOL.md."/>
  <div className="doc-columns"><aside><span className="eyebrow">SUR CETTE PAGE</span><a href="#gatt">01 · GATT</a><a href="#trames">02 · Trames</a><a href="#opcodes">03 · Opcodes</a><a href="#securite">04 · Précautions</a></aside><div className="document-prose">
   <h2 id="gatt">01. Services & caractéristiques</h2>
   <p>Un seul service applicatif en mode normal : <code>00006006-0000-1000-8000-00805f9b34fb</code>. Quatre caractéristiques suffisent à tout faire :</p>
   <CodeBlock label="GATT" code={'0x8001  écriture   commandes téléphone → montre\n0x8002  notifications  accusés (acks)\n0x8003  écriture   réponses et événements\n0x8004  notifications  événements watch → téléphone\n\nNom annoncé : ZeTime#<série>'}/>
   <p>Pas de service Nordic DFU : la mise à jour passe par un déclencheur propriétaire (<code>0x0E</code> avec la charge <code>[0x01]</code>). Les trames longues sont découpées en chunks de 20 octets ; il n’y a pas de checksum.</p>
   <h2 id="trames">02. Format des trames</h2>
   <p>Chaque message suit la même enveloppe, documentée dans le dépôt :</p>
   <CodeBlock label="HEX · FORMAT" code={'6F <cmd> <71=send / 70=request> <len:2> 00 <payload…> 8F\n\nAck : 6F 01 81 02 00 <cmd> <status> 8F   (00 = OK)'}/>
   <p>Certains événements (musique, appel, « chercher le téléphone », réponses rapides) bloquent la montre tant qu’un accusé générique n’est pas renvoyé sur <code>0x8003</code> — sans lui, l’écran ne se rafraîchit qu’après ~2-3 s de timeout.</p>
   <h2 id="opcodes">03. Familles d’opcodes</h2>
   <p>Le protocole couvre l’essentiel : heure et date, profil utilisateur, unités et langue, objectif quotidien, notifications, agenda, météo, musique/appels/alertes, alarmes et rappels, réponses rapides, suivi d’activité et sommeil, réglages simples, mode nuit, calibration des aiguilles, et upload de cadrans.</p>
   <p>Le document complet liste chaque opcode avec son payload, ses acquittements et ses pièges — y compris les commandes <strong>dangereuses</strong> (effacement flash, coupure, écritures de régions) listées dans <a href={`${repoUrl}/blob/main/docs/SAFETY.md`} target="_blank" rel="noreferrer">SAFETY.md</a>. Le projet s’appuie sur la documentation de <a href="https://zetime.artificialred.nl" target="_blank" rel="noreferrer">artificialred.nl</a> et le code Gadgetbridge (AGPL-3.0).</p>
   <h2 id="securite">04. Expérimenter avec précaution</h2>
   <p>La plupart des commandes sont de vraies actions sur du matériel réel : une mauvaise trame peut planter l’appairage, voire briquer la montre. Privilégiez la lecture, gardez une sauvegarde des partitions avant tout flash, et ne partagez jamais de captures contenant vos données personnelles.</p>
   <Button asChild variant="outline"><a href={`${repoUrl}/blob/main/docs/PROTOCOL.md`} target="_blank" rel="noreferrer">Lire PROTOCOL.md<ArrowRight/></a></Button>
  </div></div>
 </> : page === 'blog' ? <>
  <PageIntro label="LE JOURNAL DU PROJET" title="Notes d’exploration" text="Horlogerie hybride, Bluetooth et open-source : les idées et découvertes qui font avancer le projet."/>
  <ArticleGrid/>
 </> : page === 'faq' ? <>
  <PageIntro label="QUESTIONS FRÉQUENTES" title="Quelques réponses." text="L’essentiel à savoir sur le compagnon, la compatibilité et les contributions."/>
  <div className="faq-list">{faq.map((item,i) => <details key={item.question} open={i===0}><summary>{item.question}<ChevronDown className="size-4 shrink-0"/></summary><p>{item.answer}</p></details>)}</div>
 </> : <>
  <PageIntro label="LA COMMUNAUTÉ" title="Crédits & Licence" text="Un projet indépendant, animé par la curiosité et le partage des connaissances."/>
  <div className="document-prose max-w-3xl">
   <h2>Un compagnon non officiel</h2>
   <p>OpenAguja n’est ni affilié, ni approuvé, ni soutenu par MyKronoz. Les marques ZeTime et MyKronoz appartiennent à leurs propriétaires respectifs. Le projet est indépendant et communautaire.</p>
   <h2>Auteurs & contributeurs</h2>
   <p>Conçu et développé par Hougo, avec les retours de la communauté. Les travaux s’appuient sur la documentation de <a href="https://zetime.artificialred.nl" target="_blank" rel="noreferrer">artificialred.nl</a>, sur le lecteur ZeTime de <a href="https://codeberg.org/Freeyourgadget/Gadgetbridge" target="_blank" rel="noreferrer">Gadgetbridge</a> (dont une partie du code est adaptée, voir NOTICE) et sur le firmware officiel comme référence.</p>
   <h2>Licence</h2>
   <p>Le code est publié sous <strong>AGPL-3.0-or-later</strong> — copyleft fort, donc partage à l’identique exigé. Le fichier <a href={`${repoUrl}/blob/main/LICENSE`} target="_blank" rel="noreferrer">LICENSE</a> fait foi. Le site lui-même reprend le design généré avec Lovable.</p>
   <h2>Ce site</h2>
   <p>Pages statiques générées depuis le dépôt, sans compte ni tracking. Les exemples de code et de trames sont tirés de la documentation publique du projet.</p>
  </div>
 </>}
 </main>;
}
