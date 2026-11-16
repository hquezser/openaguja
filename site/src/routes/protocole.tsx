import { createFileRoute } from '@tanstack/react-router';
import { DocumentationPage } from '@/components/zetime/documentation';
export const Route = createFileRoute('/protocole')({
 head: () => ({ meta: [{ title: 'Protocole BLE — OpenAguja' }, { name: 'description', content: 'Une introduction exploratoire aux échanges Bluetooth Low Energy d’une montre hybride.' }, { property: 'og:title', content: 'Protocole BLE — OpenAguja' }, { property: 'og:description', content: 'Une introduction exploratoire aux échanges Bluetooth Low Energy d’une montre hybride.' }, { property: 'og:type', content: 'website' }, { name: 'twitter:card', content: 'summary_large_image' }] }),
 component: Page,
});
function Page() { return <DocumentationPage page="protocole"/>; }
