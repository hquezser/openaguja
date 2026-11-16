export type Locale = 'fr' | 'en';

export interface TocItem { href: string; label: string }

export type Block =
  | { type: 'h2'; id?: string; text: string }
  | { type: 'p'; text: string }
  | { type: 'code'; label: string; code: string }
  | { type: 'notice'; text: string }
  | { type: 'list'; items: string[] }
  | { type: 'cta'; label: string; href: string };

export type Section =
  | { kind: 'intro'; label: string; title: string; text: string }
  | { kind: 'features' }
  | { kind: 'columns'; toc: TocItem[]; blocks: Block[] }
  | { kind: 'prose'; blocks: Block[] }
  | { kind: 'articles' }
  | { kind: 'faq' };

export interface DocPage { sections: Section[] }

export interface Feature { icon: string; title: string; text: string; tag: string }
export interface StatusItem { label: string; done: boolean; note?: string }
export interface LogItem { date: string; text: string }
export interface NavItem { to: string; label: string }
export interface FaqItem { question: string; answer: string }

export interface ArticleSection { title: string; text: string; code?: string }
export interface Article {
  slug: string;
  title: string;
  date: string;
  tags: string[];
  readingTime: number;
  summary: string;
  content: ArticleSection[];
}

export interface HomeContent {
  terminalLine: string;
  intro1: string;
  intro2: string;
  links: { label: string; href: string }[];
  statusTitle: string;
  status: StatusItem[];
  tryTitle: string;
  tryText: string;
  codeLabel: string;
  code: string;
  logTitle: string;
  log: LogItem[];
  notesTitle: string;
  helpTitle: string;
  helpText: string;
  helpLinkLabel: string;
}

export interface UiStrings {
  nav: NavItem[];
  githubButton: string;
  githubDialogTitle: string;
  githubDialogText: string;
  repos: { name: string; desc: string; url: string }[];
  footerText: string;
  creditsLink: string;
  menuOpen: string;
  menuClose: string;
  mainNavLabel: string;
  mobileNavLabel: string;
  dialogLabel: string;
  closeLabel: string;
}

export interface LocaleContent {
  htmlLang: string;
  home: HomeContent;
  ui: UiStrings;
  pages: Record<'features' | 'install' | 'protocol' | 'credits', DocPage>;
  blogIntro: { label: string; title: string; text: string };
  faqIntro: { label: string; title: string; text: string };
  faq: FaqItem[];
  features: Feature[];
  articles: Article[];
  meta: {
    home: { title: string; description: string };
    features: { title: string; description: string };
    install: { title: string; description: string };
    protocol: { title: string; description: string };
    blog: { title: string; description: string };
    faq: { title: string; description: string };
    credits: { title: string; description: string };
  };
}
