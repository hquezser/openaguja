import { createFileRoute } from '@tanstack/react-router';
import { DocumentationPage } from '@/components/zetime/documentation';
export const Route = createFileRoute('/credits')({
 head: () => ({ meta: [{ title: 'Crédits & Licence — OpenAguja' }, { name: 'description', content: 'Informations sur le projet indépendant OpenAguja, ses contributeurs et sa licence.' }, { property: 'og:title', content: 'Crédits & Licence — OpenAguja' }, { property: 'og:description', content: 'Informations sur le projet indépendant OpenAguja, ses contributeurs et sa licence.' }, { property: 'og:type', content: 'website' }, { name: 'twitter:card', content: 'summary_large_image' }] }),
 component: Page,
});
function Page() { return <DocumentationPage page="credits"/>; }
