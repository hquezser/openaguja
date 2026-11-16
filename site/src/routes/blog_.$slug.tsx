import { createFileRoute, Link, notFound } from '@tanstack/react-router';
import { ArrowLeft } from 'lucide-react';
import { articles } from '@/data/articles';
import { CodeBlock } from '@/components/zetime/code-block';
export const Route = createFileRoute('/blog_/$slug')({
 loader: ({ params }) => { const article = articles.find(a => a.slug === params.slug); if (!article) throw notFound(); return article; },
 head: ({ loaderData }) => ({ meta: [{ title: `${loaderData?.title ?? 'Article indisponible'} — OpenAguja` }, { name: 'description', content: loaderData?.summary ?? 'Cet article est indisponible.' }, { property: 'og:title', content: `${loaderData?.title ?? 'Article indisponible'} — OpenAguja` }, { property: 'og:description', content: loaderData?.summary ?? 'Cet article est indisponible.' }, { property: 'og:type', content: 'article' }, { name: 'twitter:card', content: 'summary_large_image' }] }),
 component: ArticlePage,
});
function ArticlePage() { const article = Route.useLoaderData(); return <main className="site-container document-page"><div className="page-intro"><Link to="/blog" className="mb-8 inline-flex items-center gap-2 text-sm text-muted-foreground"><ArrowLeft className="size-4"/>Tous les articles</Link><p className="eyebrow">{article.tags.join(' / ')}</p><h1 className="mt-5 max-w-3xl text-4xl font-semibold leading-tight">{article.title}</h1><p className="mt-5 font-mono text-xs text-muted-foreground">{new Intl.DateTimeFormat('fr-FR', { dateStyle: 'long', timeZone: 'UTC' }).format(new Date(article.date))} · {article.readingTime} min de lecture</p><p className="mt-6 max-w-2xl text-base leading-8 text-muted-foreground">{article.summary}</p></div><article className="document-prose max-w-3xl">{article.content.map(section => <section key={section.title}><h2>{section.title}</h2><p>{section.text}</p>{section.code && <CodeBlock code={section.code}/>}</section>)}</article></main>; }
