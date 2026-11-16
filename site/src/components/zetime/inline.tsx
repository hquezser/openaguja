import type { ReactNode } from 'react';

/**
 * Mini-markdown inline : `code`, **gras** et [label](url).
 * Les liens internes (/chemin) restent dans la locale courante ; les liens
 * externes (https://…) s'ouvrent dans un nouvel onglet.
 */
export function renderInline(text: string, keyPrefix = 'i'): ReactNode[] {
  const nodes: ReactNode[] = [];
  const re = /(`[^`]+`)|(\*\*[^*]+\*\*)|(\[[^\]]+\]\([^)]+\))/g;
  let last = 0;
  let m: RegExpExecArray | null;
  let i = 0;
  while ((m = re.exec(text))) {
    if (m.index > last) nodes.push(text.slice(last, m.index));
    const tok = m[0];
    const key = `${keyPrefix}-${i++}`;
    if (tok.startsWith('`')) {
      nodes.push(<code key={key} className="rounded bg-muted px-1 py-0.5 font-mono text-[0.85em]">{tok.slice(1, -1)}</code>);
    } else if (tok.startsWith('**')) {
      nodes.push(<strong key={key}>{tok.slice(2, -2)}</strong>);
    } else {
      const lm = tok.match(/^\[([^\]]+)\]\(([^)]+)\)$/);
      if (lm && lm[1] !== undefined && lm[2] !== undefined) {
        const label = lm[1];
        const href = lm[2];
        const external = /^https?:\/\//.test(href);
        const internalHref = external ? href : `${import.meta.env.BASE_URL}${href.replace(/^\//, '')}`;
        nodes.push(
          external
            ? <a key={key} href={href} target="_blank" rel="noreferrer" className="text-primary underline underline-offset-4 hover:text-primary/80">{label}</a>
            : <a key={key} href={internalHref} className="text-primary underline underline-offset-4 hover:text-primary/80">{label}</a>,
        );
      } else {
        nodes.push(tok);
      }
    }
    last = m.index + tok.length;
  }
  if (last < text.length) nodes.push(text.slice(last));
  return nodes;
}
