import { createFileRoute, Link, notFound } from '@tanstack/react-router';
import { ArrowLeft } from 'lucide-react';
import { getContent } from '@/data/i18n';
import { CodeBlock } from '@/components/zetime/code-block';
import type { Locale } from '@/data/types';

const locale: Locale = 'fr';
const backTo = '/blog';
const backLabel = 'Tous les articles';
const dateLocale = 'fr-FR';
const readLabel = 'min de lecture';
const missingTitle = 'Article indisponible';
const missingDesc = 'Cet article est indisponible.';

export const Route = createFileRoute('/blog_/$slug')({
 loader: ({ params }) => { const article = getContent(locale).articles.find(a => a.slug === params.slug); if (!article) throw notFound(); return article; },
 head: ({ loaderData }) => ({ meta: [{ title: `${loaderData?.title ?? missingTitle} — OpenAguja` }, { name: 'description', content: loaderData?.summary ?? missingDesc }, { property: 'og:title', content: `${loaderData?.title ?? missingTitle} — OpenAguja` }, { property: 'og:description', content: loaderData?.summary ?? missingDesc }, { property: 'og:type', content: 'article' }, { name: 'twitter:card', content: 'summary_large_image' }] }),
 component: ArticlePage,
});
function ArticlePage() { const article = Route.useLoaderData(); return <main className="site-container document-page"><div className="page-intro"><Link to={backTo as never} className="mb-8 inline-flex items-center gap-2 text-sm text-muted-foreground"><ArrowLeft className="size-4"/>{backLabel}</Link><p className="eyebrow">{article.tags.join(' / ')}</p><h1 className="mt-5 max-w-3xl text-4xl font-semibold leading-tight">{article.title}</h1><p className="mt-5 font-mono text-xs text-muted-foreground">{new Intl.DateTimeFormat(dateLocale, { dateStyle: 'long', timeZone: 'UTC' }).format(new Date(article.date))} · {article.readingTime} {readLabel}</p><p className="mt-6 max-w-2xl text-base leading-8 text-muted-foreground">{article.summary}</p></div><article className="document-prose max-w-3xl">{article.content.map(section => <section key={section.title}>{section.title ? <h2>{section.title}</h2> : null}{section.text ? <p>{section.text}</p> : null}{section.code && <CodeBlock code={section.code}/>}</section>)}</article></main>; }
