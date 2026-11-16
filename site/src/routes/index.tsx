import { createFileRoute, Link } from '@tanstack/react-router';
import { ArticleGrid } from '@/components/zetime/documentation';
import { CodeBlock } from '@/components/zetime/code-block';
import { WatchMark } from '@/components/zetime/logo';
import { homeStatus, homeLog, repoUrl } from '@/data/project';

export const Route = createFileRoute('/')({ head: () => ({ meta: [
  { title: 'OpenAguja — un compagnon libre pour montres hybrides' },
  { name: 'description', content: 'OpenAguja : application iOS, CLI et protocole ouvert pour les montres hybrides MyKronoz ZeTime. AGPL-3.0, sans cloud.' },
  { property: 'og:title', content: 'OpenAguja — un compagnon libre pour montres hybrides' },
  { property: 'og:description', content: 'Application iOS et CLI open-source pour les montres hybrides ZeTime : notifications, actions, télémétrie et firmware images. AGPL-3.0.' },
  { property: 'og:type', content: 'website' }, { name: 'twitter:card', content: 'summary' },
] }), component: Index });

function Index() {
  return <main className="site-container home-readme">
    <section className="readme-head">
      <p className="font-mono text-xs text-muted-foreground">~/projets/openaguja $ cat README.md</p>
      <h1 className="mt-6 flex flex-wrap items-center gap-x-4 gap-y-2 font-mono text-4xl font-semibold md:text-6xl"><WatchMark className="size-10 shrink-0 md:size-14"/><span>OpenAguja<span className="text-primary">_</span></span></h1>
      <p className="mt-6 max-w-2xl text-lg leading-8">Salut. J’avais une montre hybride dans un tiroir et une appli officielle capricieuse. Alors j’ai sorti un sniffer BLE, je me suis appuyé sur les travaux de la communauté, et j’ai fini par écrire un compagnon complet.</p>
      <p className="mt-4 max-w-2xl leading-7 text-muted-foreground">OpenAguja, c’est le résultat : une app iOS, un CLI, un protocole documenté et des outils pour bidouiller les images de la montre. AGPL-3.0, sans compte, sans cloud — vos données vont où vous voulez.</p>
      <div className="mt-8 flex flex-wrap gap-x-6 gap-y-2 font-mono text-sm">
        <a href={repoUrl} target="_blank" rel="noreferrer" className="readme-link">→ github.com/hquezser/openaguja</a>
        <Link to="/installation" className="readme-link">→ installer</Link>
        <Link to="/protocole" className="readme-link">→ lire les notes protocole</Link>
        <Link to="/faq" className="readme-link">→ faq</Link>
      </div>
    </section>

    <section className="readme-block">
      <h2 className="readme-title">## Où on en est</h2>
      <ul className="status-list">{homeStatus.map(s => <li key={s.label}><span className={`font-mono ${s.done ? 'text-primary' : 'text-muted-foreground'}`}>[{s.done ? 'x' : ' '}]</span><span>{s.label}</span>{s.note && <em>{s.note}</em>}</li>)}</ul>
    </section>

    <section className="readme-block">
      <h2 className="readme-title">## Essayer</h2>
      <p className="mb-4 text-muted-foreground">Le dépôt est public. Pour l’app iOS, pas d’App Store : SideStore, AltStore ou build Xcode — tout est dans le guide d’installation.</p>
      <CodeBlock label="SHELL" code={'git clone https://github.com/hquezser/openaguja.git\ncd openaguja\n# puis suivre docs/INSTALL.md'}/>
    </section>

    <section className="readme-block">
      <h2 className="readme-title">## Carnet de bord</h2>
      <ol className="log-list">{homeLog.map(l => <li key={l.date}><time className="font-mono text-xs text-muted-foreground">{l.date}</time><span>{l.text}</span></li>)}</ol>
    </section>

    <section className="readme-block">
      <h2 className="readme-title">## Notes plus longues</h2>
      <ArticleGrid/>
    </section>

    <section className="readme-block">
      <h2 className="readme-title">## Donner un coup de main</h2>
      <p className="max-w-2xl leading-7 text-muted-foreground">Vous avez la même montre ? Une capture BLE, un retour de test ou une correction de doc, tout aide. Pas besoin d’être expert, il suffit d’être curieux. Les détails sont dans <Link to="/credits" className="readme-link">crédits & licence</Link>.</p>
    </section>
  </main>;
}
