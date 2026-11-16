import { createFileRoute } from '@tanstack/react-router';
import { DocumentationPage } from '@/components/zetime/documentation';
export const Route = createFileRoute('/faq')({
 head: () => ({ meta: [{ title: 'Questions fréquentes — OpenAguja' }, { name: 'description', content: 'Les réponses aux questions sur le projet OpenAguja, la compatibilité et les contributions.' }, { property: 'og:title', content: 'Questions fréquentes — OpenAguja' }, { property: 'og:description', content: 'Les réponses aux questions sur le projet OpenAguja, la compatibilité et les contributions.' }, { property: 'og:type', content: 'website' }, { name: 'twitter:card', content: 'summary_large_image' }] }),
 component: Page,
});
function Page() { return <DocumentationPage page="faq"/>; }
