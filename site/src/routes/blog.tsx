import { createFileRoute } from '@tanstack/react-router';
import { DocumentationPage } from '@/components/zetime/documentation';
export const Route = createFileRoute('/blog')({
 head: () => ({ meta: [{ title: 'Journal du projet — OpenAguja' }, { name: 'description', content: 'Articles et notes d’exploration sur les montres hybrides, Bluetooth et l’open-source.' }, { property: 'og:title', content: 'Journal du projet — OpenAguja' }, { property: 'og:description', content: 'Articles et notes d’exploration sur les montres hybrides, Bluetooth et l’open-source.' }, { property: 'og:type', content: 'website' }, { name: 'twitter:card', content: 'summary_large_image' }] }),
 component: Page,
});
function Page() { return <DocumentationPage page="blog"/>; }
