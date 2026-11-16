import type { Locale } from '@/data/types';
import { articleIndex, getContent } from '@/data/i18n';

/** Locale d'une URL : '/en/…' → 'en', tout le reste → 'fr'. */
export function localeOfPath(pathname: string): Locale {
  return pathname === '/en' || pathname.startsWith('/en/') ? 'en' : 'fr';
}

const ROUTE_MAP: Record<string, { fr: string; en: string }> = {
  '/': { fr: '/', en: '/en' },
  '/fonctionnalites': { fr: '/fonctionnalites', en: '/en/features' },
  '/installation': { fr: '/installation', en: '/en/install' },
  '/protocole': { fr: '/protocole', en: '/en/protocol' },
  '/blog': { fr: '/blog', en: '/en/blog' },
  '/faq': { fr: '/faq', en: '/en/faq' },
  '/credits': { fr: '/credits', en: '/en/credits' },
};

/** Traduit un pathname vers l'autre locale en conservant la page (et le slug d'article). */
export function pathForLocale(pathname: string, target: Locale): string {
  const current = localeOfPath(pathname);
  if (current === target) return pathname;

  const bare = current === 'en' ? pathname.replace(/^\/en/, '') || '/' : pathname;
  const base = bare.replace(/\/$/, '') || '/';

  // Article de blog : /blog/<slug> → même index dans l'autre locale.
  const blogMatch = base.match(/^\/blog\/([^/]+)$/);
  if (blogMatch && blogMatch[1] !== undefined) {
    const idx = articleIndex(current, decodeURIComponent(blogMatch[1]));
    if (idx >= 0) {
      const slug = getContent(target).articles[idx]?.slug;
      if (slug) return target === 'en' ? `/en/blog/${slug}` : `/blog/${slug}`;
    }
    return target === 'en' ? '/en/blog' : '/blog';
  }

  const mapped = ROUTE_MAP[base] ?? { fr: '/', en: '/en' };
  return target === 'en' ? mapped.en : mapped.fr;
}
