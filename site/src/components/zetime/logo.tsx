import { Link } from '@tanstack/react-router';

/** Petit cadran dessiné à la main : clin d'œil à la montre hybride du projet. */
export function WatchMark({ className = 'size-6' }: { className?: string }) {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true" className={className} fill="none" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" strokeLinejoin="round">
      <path d="M8.7 4.6 8.3 1.7h7.4l-.4 2.9" />
      <path d="M8.7 19.4 8.3 22.3h7.4l-.4-2.9" />
      <circle cx="12" cy="12" r="6.5" />
      <path className="text-primary" d="M12 8.7V12l2.7 1.7" />
    </svg>
  );
}

export function Brand({ className = '' }: { className?: string }) {
  return (
    <Link to="/" className={`brand ${className}`.trim()}>
      <WatchMark className="size-[26px] shrink-0" />
      <span className="font-mono">OpenAguja<span className="text-primary">_</span></span>
    </Link>
  );
}
