import { fr } from './content.fr';
import { en } from './content.en';
import type { Locale, LocaleContent } from './types';

export const content: Record<Locale, LocaleContent> = { fr, en };
export const locales: Locale[] = ['fr', 'en'];
export const defaultLocale: Locale = 'fr';

export function getContent(locale: Locale): LocaleContent {
  return content[locale] ?? content[defaultLocale];
}

export function getArticle(locale: Locale, slug: string) {
  return getContent(locale).articles.find((a) => a.slug === slug);
}

export function articleIndex(locale: Locale, slug: string) {
  return getContent(locale).articles.findIndex((a) => a.slug === slug);
}
