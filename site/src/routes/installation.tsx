import { createFileRoute } from '@tanstack/react-router';
import { DocumentationPage } from '@/components/zetime/documentation';
export const Route = createFileRoute('/installation')({
 head: () => ({ meta: [{ title: 'Installation — OpenAguja' }, { name: 'description', content: 'Les étapes pour préparer votre environnement et installer le projet OpenAguja.' }, { property: 'og:title', content: 'Installation — OpenAguja' }, { property: 'og:description', content: 'Les étapes pour préparer votre environnement et installer le projet OpenAguja.' }, { property: 'og:type', content: 'website' }, { name: 'twitter:card', content: 'summary_large_image' }] }),
 component: Page,
});
function Page() { return <DocumentationPage page="installation"/>; }
