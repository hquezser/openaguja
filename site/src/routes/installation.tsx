import { createFileRoute } from '@tanstack/react-router';
import { DocumentationPage } from '@/components/zetime/documentation';
import { getContent } from '@/data/i18n';

const meta = getContent('fr').meta.install;

export const Route = createFileRoute('/installation')({
 head: () => ({ meta: [
  { title: meta.title }, { name: 'description', content: meta.description },
  { property: 'og:title', content: meta.title }, { property: 'og:description', content: meta.description },
  { property: 'og:type', content: 'website' }, { name: 'twitter:card', content: 'summary_large_image' },
] }),
 component: Page,
});
function Page() { return <DocumentationPage page="install" locale="fr"/>; }
