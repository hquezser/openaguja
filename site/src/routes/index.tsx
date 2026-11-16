import { createFileRoute } from '@tanstack/react-router';
import { HomePage } from '@/components/zetime/home';
import { getContent } from '@/data/i18n';

const meta = getContent('fr').meta.home;

export const Route = createFileRoute('/')({ head: () => ({ meta: [
  { title: meta.title },
  { name: 'description', content: meta.description },
  { property: 'og:title', content: meta.title },
  { property: 'og:description', content: meta.description },
  { property: 'og:type', content: 'website' }, { name: 'twitter:card', content: 'summary' },
] }), component: () => <HomePage locale="fr" /> });
