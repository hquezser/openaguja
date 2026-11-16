import { Link } from '@tanstack/react-router';
import { ArrowRight, Bluetooth, Bell, Code2, Radio, Watch, ChevronDown, ArrowUpRight } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { CodeBlock } from './code-block';
import { renderInline } from './inline';
import { getContent } from '@/data/i18n';
import type { Block, Locale, Section, TocItem } from '@/data/types';

export type PageKey = 'features' | 'install' | 'protocol' | 'blog' | 'faq' | 'credits';

const FEATURE_ICONS = [Bluetooth, Bell, Code2];
const ARTICLE_ICONS = [Watch, Radio, Code2];

export function FeatureGrid({ locale }: { locale: Locale }) {
  const { features } = getContent(locale);
  return (
    <div className="feature-grid">
      {features.map((f, i) => {
        const Icon = FEATURE_ICONS[i] ?? Code2;
        return (
          <article className="feature-card" key={f.title}>
            <div className="flex items-center justify-between"><Icon className="size-6 text-primary" /><ArrowUpRight className="size-4 text-muted-foreground" /></div>
            <h3 className="mt-7 text-lg font-semibold">{f.title}</h3>
            <p className="mt-3 text-sm leading-6 text-muted-foreground">{f.text}</p>
            <p className="mt-7 font-mono text-[10px] tracking-widest text-muted-foreground">{f.tag}</p>
          </article>
        );
      })}
    </div>
  );
}

export function ArticleGrid({ locale }: { locale: Locale }) {
  const { articles } = getContent(locale);
  return (
    <div className="article-grid">
      {articles.map((a, i) => {
        const Icon = ARTICLE_ICONS[i] ?? Code2;
        const to = locale === 'en' ? '/en/blog/$slug' : '/blog/$slug';
        return (
          <Link to={to} params={{ slug: a.slug }} key={a.slug} className="article-card">
            <div className={`article-visual article-visual-${i}`}>
              <span className="font-mono text-primary"><Icon className="size-16" /></span>
              <span className="article-visual-label">{['HYBRID / 01', 'BLE / 02', 'OPEN SOURCE / 03'][i]}</span>
            </div>
            <div className="py-5">
              <div className="flex justify-between font-mono text-[10px] text-muted-foreground"><span>{a.tags[0]}</span><span>{a.readingTime} MIN</span></div>
              <h3 className="mt-3 text-lg font-semibold leading-7">{a.title}</h3>
              <p className="mt-2 text-sm leading-6 text-muted-foreground">{a.summary}</p>
              <span className="mt-5 inline-flex items-center gap-2 text-xs text-primary">{locale === 'en' ? 'Read article' : 'Lire l’article'} <ArrowRight className="size-3" /></span>
            </div>
          </Link>
        );
      })}
    </div>
  );
}

export function PageIntro({ label, title, text }: { label: string; title: string; text: string }) {
  return (
    <div className="page-intro">
      <span className="eyebrow">{label}</span>
      <h1 className="mt-5 font-display text-4xl font-semibold md:text-5xl">{title}</h1>
      <p className="mt-5 max-w-2xl text-base leading-8 text-muted-foreground">{text}</p>
    </div>
  );
}

function renderBlock(block: Block, key: number) {
  switch (block.type) {
    case 'h2':
      return block.id
        ? <h2 key={key} id={block.id}>{renderInline(block.text, `b${key}`)}</h2>
        : <h2 key={key}>{renderInline(block.text, `b${key}`)}</h2>;
    case 'p':
      return <p key={key}>{renderInline(block.text, `b${key}`)}</p>;
    case 'code':
      return <CodeBlock key={key} label={block.label} code={block.code} />;
    case 'notice':
      return <div key={key} className="notice">{renderInline(block.text, `b${key}`)}</div>;
    case 'list':
      return <ul key={key} className="list-disc space-y-2 pl-5 text-sm leading-7">{block.items.map((it, j) => <li key={j}>{renderInline(it, `b${key}-${j}`)}</li>)}</ul>;
    case 'cta': {
      const external = /^https?:\/\//.test(block.href);
      return (
        <div key={key}>
          <Button asChild variant="outline">
            {external
              ? <a href={block.href} target="_blank" rel="noreferrer">{block.label}<ArrowRight /></a>
              : <a href={block.href}>{block.label}<ArrowRight /></a>}
          </Button>
        </div>
      );
    }
  }
}

function renderSection(section: Section, locale: Locale, key: number) {
  switch (section.kind) {
    case 'intro':
      return <PageIntro key={key} label={section.label} title={section.title} text={section.text} />;
    case 'features':
      return <FeatureGrid key={key} locale={locale} />;
    case 'columns': {
      const tocLabel = locale === 'en' ? 'ON THIS PAGE' : 'SUR CETTE PAGE';
      return (
        <div key={key} className="doc-columns">
          <aside>
            <span className="eyebrow">{tocLabel}</span>
            {section.toc.map((t: TocItem) => <a key={t.href} href={t.href}>{t.label}</a>)}
          </aside>
          <div className="document-prose">{section.blocks.map(renderBlock)}</div>
        </div>
      );
    }
    case 'prose':
      return <div key={key} className="document-prose max-w-3xl">{section.blocks.map(renderBlock)}</div>;
    case 'articles':
      return <ArticleGrid key={key} locale={locale} />;
    case 'faq': {
      const { faq } = getContent(locale);
      return (
        <div key={key} className="faq-list">
          {faq.map((item, i) => (
            <details key={item.question} open={i === 0}>
              <summary>{item.question}<ChevronDown className="size-4 shrink-0" /></summary>
              <p>{renderInline(item.answer, `faq-${i}`)}</p>
            </details>
          ))}
        </div>
      );
    }
  }
}

export function DocumentationPage({ page, locale }: { page: PageKey; locale: Locale }) {
  const c = getContent(locale);

  if (page === 'blog') {
    return (
      <main className="site-container document-page">
        <PageIntro label={c.blogIntro.label} title={c.blogIntro.title} text={c.blogIntro.text} />
        <ArticleGrid locale={locale} />
      </main>
    );
  }
  if (page === 'faq') {
    return (
      <main className="site-container document-page">
        <PageIntro label={c.faqIntro.label} title={c.faqIntro.title} text={c.faqIntro.text} />
        {renderSection({ kind: 'faq' }, locale, 0)}
      </main>
    );
  }

  const docPage = c.pages[page];
  return (
    <main className="site-container document-page">
      {docPage.sections.map((s, i) => renderSection(s, locale, i))}
    </main>
  );
}
