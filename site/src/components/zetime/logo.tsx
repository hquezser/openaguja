import { Link } from '@tanstack/react-router';

const markUrl = `${import.meta.env.BASE_URL}brand/openaguja-mark.webp`;
const lockupUrl = `${import.meta.env.BASE_URL}brand/openaguja-lockup.webp`;

/** Marque officielle : la montre du banner OpenAguja, détourée. */
export function BrandMark({ className = 'h-7 w-auto' }: { className?: string }) {
  return <img src={markUrl} alt="" aria-hidden="true" className={className} />;
}

/** Lockup complet (montre + wordmark) pour les grands espaces de marque. */
export function BrandLockup({ className = 'h-16 w-auto' }: { className?: string }) {
  return <img src={lockupUrl} alt="OpenAguja" className={className} />;
}

export function Brand({ className = '', homeTo = '/' }: { className?: string; homeTo?: string }) {
  return (
    <Link to={homeTo as never} className={`brand ${className}`.trim()}>
      <BrandMark className="h-[26px] w-auto shrink-0" />
      <span className="font-mono">OpenAguja<span className="text-primary">_</span></span>
    </Link>
  );
}
