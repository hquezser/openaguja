import { Link } from '@tanstack/react-router';
import { ArticleGrid } from './documentation';
import { CodeBlock } from './code-block';
import { BrandLockup } from './logo';
import { getContent } from '@/data/i18n';
import type { Locale } from '@/data/types';

export function HomePage({ locale }: { locale: Locale }) {
  const c = getContent(locale);
  const h = c.home;
  const creditsTo = locale === 'en' ? '/en/credits' : '/credits';
  const readmeLink = 'readme-link';

  return (
    <main className="site-container home-readme">
      <section className="readme-head">
        <p className="font-mono text-xs text-muted-foreground">{h.terminalLine}</p>
        <h1 className="mt-6 flex flex-wrap items-center gap-x-4 gap-y-2 font-mono text-4xl font-semibold md:text-6xl">
          <BrandLockup className="h-12 w-auto shrink-0 md:h-16" /><span className="sr-only">OpenAguja</span>
        </h1>
        <p className="mt-6 max-w-2xl text-lg leading-8">{h.intro1}</p>
        <p className="mt-4 max-w-2xl leading-7 text-muted-foreground">{h.intro2}</p>
        <div className="mt-8 flex flex-wrap gap-x-6 gap-y-2 font-mono text-sm">
          {h.links.map((l) =>
            /^https?:\/\//.test(l.href)
              ? <a key={l.label} href={l.href} target="_blank" rel="noreferrer" className={readmeLink}>{l.label}</a>
              : <Link key={l.label} to={l.href as never} className={readmeLink}>{l.label}</Link>,
          )}
        </div>
      </section>

      <section className="readme-block">
        <h2 className="readme-title">{h.statusTitle}</h2>
        <ul className="status-list">
          {h.status.map((s) => (
            <li key={s.label}>
              <span className={`font-mono ${s.done ? 'text-primary' : 'text-muted-foreground'}`}>[{s.done ? 'x' : ' '}]</span>
              <span>{s.label}</span>{s.note && <em>{s.note}</em>}
            </li>
          ))}
        </ul>
      </section>

      <section className="readme-block">
        <h2 className="readme-title">{h.tryTitle}</h2>
        <p className="mb-4 text-muted-foreground">{h.tryText}</p>
        <CodeBlock label={h.codeLabel} code={h.code} />
      </section>

      <section className="readme-block">
        <h2 className="readme-title">{h.logTitle}</h2>
        <ol className="log-list">
          {h.log.map((l) => <li key={l.date}><time className="font-mono text-xs text-muted-foreground">{l.date}</time><span>{l.text}</span></li>)}
        </ol>
      </section>

      <section className="readme-block">
        <h2 className="readme-title">{h.notesTitle}</h2>
        <ArticleGrid locale={locale} />
      </section>

      <section className="readme-block">
        <h2 className="readme-title">{h.helpTitle}</h2>
        <p className="max-w-2xl leading-7 text-muted-foreground">
          {h.helpText} <Link to={creditsTo as never} className={readmeLink}>{h.helpLinkLabel}</Link>.
        </p>
      </section>
    </main>
  );
}
