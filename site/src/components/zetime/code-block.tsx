import { useState } from 'react';
import { Check, Copy } from 'lucide-react';
import { Button } from '@/components/ui/button';
export function CodeBlock({ code, label = 'EXEMPLE' }: { code: string; label?: string }) {
  const [copied, setCopied] = useState(false);
  const [error, setError] = useState(false);
  async function copy() {
    try { await navigator.clipboard.writeText(code); setCopied(true); setError(false); setTimeout(() => setCopied(false), 2000); }
    catch { setError(true); }
  }
  return <div className="code-block"><div className="flex items-center justify-between border-b border-border px-4 py-2"><span className="font-mono text-xs text-muted-foreground">{label}</span><Button variant="ghost" size="sm" onClick={copy}>{copied ? <Check /> : <Copy />}{copied ? 'Copié' : 'Copier'}</Button></div><pre className="overflow-x-auto p-5 text-sm leading-7"><code>{code.split('\n').map((line, i) => <span key={i} className={`block ${line.startsWith('#') ? 'text-muted-foreground' : 'text-primary'}`}>{line || ' '}</span>)}</code></pre>{error && <p role="alert" className="px-4 pb-3 text-sm text-destructive">Copie indisponible. Sélectionnez le texte pour le copier.</p>}</div>;
}
