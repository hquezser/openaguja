import { Link, useRouterState } from '@tanstack/react-router';
import { useState } from 'react';
import { ArrowUpRight, ExternalLink, Github, Menu, X } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { getContent } from '@/data/i18n';
import { localeOfPath, pathForLocale } from '@/lib/locale';
import type { Locale } from '@/data/types';
import { Brand } from '@/components/zetime/logo';

function LangSwitcher({ locale }: { locale: Locale }) {
  const pathname = useRouterState({ select: (s) => s.location.pathname });
  const base = import.meta.env.BASE_URL;
  const frHref = `${base}${pathForLocale(pathname, 'fr').replace(/^\//, '')}`;
  const enHref = `${base}${pathForLocale(pathname, 'en').replace(/^\//, '')}`;
  return (
    <nav aria-label="Language / Langue" className="flex items-center gap-1 font-mono text-xs">
      <a href={frHref} hrefLang="fr" aria-current={locale === 'fr' ? 'true' : undefined}
        className={`rounded px-1.5 py-1 ${locale === 'fr' ? 'text-primary' : 'text-muted-foreground hover:text-foreground'}`}>FR</a>
      <span className="text-muted-foreground/50">/</span>
      <a href={enHref} hrefLang="en" aria-current={locale === 'en' ? 'true' : undefined}
        className={`rounded px-1.5 py-1 ${locale === 'en' ? 'text-primary' : 'text-muted-foreground hover:text-foreground'}`}>EN</a>
    </nav>
  );
}

export function SiteHeader({ locale }: { locale: Locale }) {
  const [open, setOpen] = useState(false);
  const [github, setGithub] = useState(false);
  const ui = getContent(locale).ui;
  const homeTo = locale === 'en' ? '/en' : '/';
  return (
    <>
      <header className="site-header">
        <div className="site-container flex h-[76px] items-center justify-between gap-6">
          <Brand homeTo={homeTo} />
          <nav aria-label={ui.mainNavLabel} className="desktop-nav">
            {ui.nav.map((item) => (
              <Link key={item.to} to={item.to as never}
                activeOptions={{ exact: item.to === '/' || item.to === '/en' }}
                activeProps={{ className: 'nav-active' }}>{item.label}</Link>
            ))}
          </nav>
          <div className="flex items-center gap-3">
            <LangSwitcher locale={locale} />
            <Button variant="outline" size="sm" className="github-button" onClick={() => setGithub(true)}>
              <Github />{ui.githubButton}<ArrowUpRight className="size-3" />
            </Button>
            <Button variant="ghost" size="icon" className="mobile-menu" aria-label={open ? ui.menuClose : ui.menuOpen} onClick={() => setOpen(!open)}>
              {open ? <X /> : <Menu />}
            </Button>
          </div>
        </div>
        {open && (
          <nav aria-label={ui.mobileNavLabel} className="mobile-nav">
            {ui.nav.map((item) => <Link key={item.to} to={item.to as never} onClick={() => setOpen(false)}>{item.label}</Link>)}
            <div className="px-2 py-2"><LangSwitcher locale={locale} /></div>
            <Button variant="outline" onClick={() => { setGithub(true); setOpen(false); }}><Github />{ui.githubButton}</Button>
          </nav>
        )}
      </header>
      {github && (
        <div className="modal-backdrop" onClick={() => setGithub(false)}>
          <section role="dialog" aria-modal="true" aria-label={ui.dialogLabel} className="github-dialog" onClick={(e) => e.stopPropagation()}>
            <div className="flex justify-between"><Github className="text-primary" /><Button variant="ghost" size="icon" aria-label={ui.closeLabel} onClick={() => setGithub(false)}><X /></Button></div>
            <h2 className="mt-4 text-xl font-semibold">{ui.githubDialogTitle}</h2>
            <p className="mt-3 text-sm leading-6 text-muted-foreground">{ui.githubDialogText}</p>
            <div className="mt-5 space-y-3">
              {ui.repos.map((r) => (
                <a key={r.name} href={r.url} target="_blank" rel="noreferrer" className="repo-link">
                  <div><p className="font-mono text-sm font-semibold text-primary">{r.name}</p><p className="text-xs text-muted-foreground">{r.desc}</p></div>
                  <ExternalLink className="size-4 shrink-0 text-muted-foreground" />
                </a>
              ))}
            </div>
          </section>
        </div>
      )}
    </>
  );
}

export function SiteFooter({ locale }: { locale: Locale }) {
  const ui = getContent(locale).ui;
  const creditsTo = locale === 'en' ? '/en/credits' : '/credits';
  return (
    <footer className="border-t border-border">
      <div className="site-container flex flex-wrap items-center justify-between gap-5 py-8">
        <Brand className="text-lg" homeTo={locale === 'en' ? '/en' : '/'} />
        <p className="text-xs text-muted-foreground">{ui.footerText}</p>
        <Link to={creditsTo as never} className="text-xs text-muted-foreground hover:text-primary">{ui.creditsLink} <ArrowUpRight className="ml-1 inline size-3" /></Link>
      </div>
    </footer>
  );
}
