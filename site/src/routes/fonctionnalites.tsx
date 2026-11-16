import { createFileRoute } from '@tanstack/react-router';
import { DocumentationPage } from '@/components/zetime/documentation';
export const Route = createFileRoute('/fonctionnalites')({
 head: () => ({ meta: [{ title: 'Fonctionnalités — OpenAguja' }, { name: 'description', content: 'Explorez les possibilités du projet OpenAguja : Bluetooth LE, notifications et protocole ouvert.' }, { property: 'og:title', content: 'Fonctionnalités — OpenAguja' }, { property: 'og:description', content: 'Explorez les possibilités du projet OpenAguja : Bluetooth LE, notifications et protocole ouvert.' }, { property: 'og:type', content: 'website' }, { name: 'twitter:card', content: 'summary_large_image' }] }),
 component: Page,
});
function Page() { return <DocumentationPage page="fonctionnalites"/>; }
