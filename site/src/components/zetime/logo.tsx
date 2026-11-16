import { Link } from '@tanstack/react-router';

const lockupUrl = `${import.meta.env.BASE_URL}brand/openaguja-lockup.webp`;

/** Lockup complet (montre + wordmark) pour les grands espaces de marque. */
export function BrandLockup({ className = 'h-16 w-auto' }: { className?: string }) {
  return <img src={lockupUrl} alt="OpenAguja" className={className} />;
}

/** Marque header/footer : le lockup du banner, sans texte additionnel. */
export function Brand({ className = '', homeTo = '/' }: { className?: string; homeTo?: string }) {
  return (
    <Link to={homeTo as never} className={`brand ${className}`.trim()} aria-label="OpenAguja">
      <img src={lockupUrl} alt="OpenAguja" className="h-10 w-auto" />
    </Link>
  );
}
