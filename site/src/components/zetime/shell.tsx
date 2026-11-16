import { Link } from '@tanstack/react-router';
import { useState } from 'react';
import { ArrowUpRight, ExternalLink, Github, Menu, X } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { navigation, repoUrl, labUrl } from '@/data/project';
import { Brand } from '@/components/zetime/logo';

const repos = [
  { name: 'openaguja', desc: 'App iOS, CLI, protocole et documentation', url: repoUrl },
  { name: 'openaguja-lab', desc: 'Outils d’images firmware (icônes, logo de boot)', url: labUrl },
];

export function SiteHeader() {
 const [open, setOpen] = useState(false);
 const [github, setGithub] = useState(false);
 return <><header className="site-header"><div className="site-container flex h-[76px] items-center justify-between gap-6"><Brand /><nav aria-label="Navigation principale" className="desktop-nav">{navigation.map(item => <Link key={item.to} to={item.to} activeOptions={{ exact: item.to === '/' }} activeProps={{ className: 'nav-active' }}>{item.label}</Link>)}</nav><Button variant="outline" size="sm" className="github-button" onClick={() => setGithub(true)}><Github />GitHub<ArrowUpRight className="size-3"/></Button><Button variant="ghost" size="icon" className="mobile-menu" aria-label={open ? 'Fermer le menu' : 'Ouvrir le menu'} onClick={() => setOpen(!open)}>{open ? <X/> : <Menu/>}</Button></div>{open && <nav aria-label="Navigation mobile" className="mobile-nav">{navigation.map(item => <Link key={item.to} to={item.to} onClick={() => setOpen(false)}>{item.label}</Link>)}<Button variant="outline" onClick={() => { setGithub(true); setOpen(false); }}><Github/>GitHub</Button></nav>}</header>{github && <div className="modal-backdrop" onClick={() => setGithub(false)}><section role="dialog" aria-modal="true" aria-label="Dépôts GitHub" className="github-dialog" onClick={e => e.stopPropagation()}><div className="flex justify-between"><Github className="text-primary"/><Button variant="ghost" size="icon" aria-label="Fermer" onClick={() => setGithub(false)}><X/></Button></div><h2 className="mt-4 text-xl font-semibold">Le code est ouvert</h2><p className="mt-3 text-sm leading-6 text-muted-foreground">Deux dépôts publics, licence AGPL-3.0. Issues et contributions bienvenues.</p><div className="mt-5 space-y-3">{repos.map(r => <a key={r.name} href={r.url} target="_blank" rel="noreferrer" className="repo-link"><div><p className="font-mono text-sm font-semibold text-primary">{r.name}</p><p className="text-xs text-muted-foreground">{r.desc}</p></div><ExternalLink className="size-4 shrink-0 text-muted-foreground"/></a>)}</div></section></div>}</>;
}
export function SiteFooter() { return <footer className="border-t border-border"><div className="site-container flex flex-wrap items-center justify-between gap-5 py-8"><Brand className="text-lg" /><p className="text-xs text-muted-foreground">Fait sur un coin de bureau, offert à qui en veut.</p><Link to="/credits" className="text-xs text-muted-foreground hover:text-primary">Crédits & Licence <ArrowUpRight className="ml-1 inline size-3"/></Link></div></footer>; }
