import type {ReactNode} from 'react';
import clsx from 'clsx';
import Link from '@docusaurus/Link';
import Head from '@docusaurus/Head';
import useDocusaurusContext from '@docusaurus/useDocusaurusContext';
import Layout from '@theme/Layout';
import styles from './index.module.css';
import {useEffect, useRef} from 'react';

function HomepageHeader() {
  const {siteConfig} = useDocusaurusContext();

  return (
    <header className={clsx('hero', styles.heroBanner)}>
      <div className={clsx('container', styles.heroContainer)}>

        <div className={styles.heroBrand}>
            <div className={styles.heroBrandGlow}>
                <img src="/Reheaven/img/reheaven_logo.svg" alt="" />
                <img src="/Reheaven/img/reheaven_text.svg" alt="" />
            </div>

            <div className={styles.heroBrandImage}>
                <img src="/Reheaven/img/reheaven_logo.svg" alt="" className={styles.heroLogo} />
                <img src="/Reheaven/img/reheaven_text.svg" alt={siteConfig.title} className={styles.heroWordmark} />
            </div>
        </div>

        <p className={styles.description}>
            <span className={styles.descriptionQuote}>
                "Ascend your game state management with a simple, powerful signal system."
            </span>
            <span className={styles.descriptionSignature}>
                - The Wind
                <img
                src="/Reheaven/img/rose_mouth_emoji.png"
                alt=""
                className={styles.descriptionEmoji}
                draggable={false}
                />
            </span>
        </p>

        <div className={styles.statusBadges}>
            <a
                href="https://github.com/wiindsom/Reheaven/actions/workflows/ci.yaml"
                target="_blank"
                rel="noopener noreferrer"
                className={styles.statusBadge}>
                <span>CI</span>
                <strong>Passing</strong>
            </a>

            <a
                href="https://wiindsom.github.io/Reheaven/"
                target="_blank"
                rel="noopener noreferrer"
                className={styles.statusBadge}>
                <span>Docs</span>
                <strong>Passing</strong>
            </a>
        </div>

        <div className={styles.buttons}>
            <Link
                className={clsx(
                    "button button--secondary button--lg",
                    styles.getStartedButton
                )}
                to="/docs/intro"
                >
                Introduction →
            </Link>
        </div>
      </div>
    </header>
  );
}

export default function Home(): ReactNode {
  const {siteConfig} = useDocusaurusContext();
  const rootRef = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    const root = rootRef.current;
    if (!root) return;

    const applyFooterHeight = () => {
      const footer = document.querySelector('footer.footer');
      const h = footer ? footer.getBoundingClientRect().height : 0;
      root.style.setProperty('--homepage-footer-height', `${h}px`);
    };

    applyFooterHeight();

    const footer = document.querySelector('footer.footer');
    const ro = footer ? new ResizeObserver(applyFooterHeight) : null;
    if (footer && ro) ro.observe(footer);

    window.addEventListener('resize', applyFooterHeight);

    return () => {
      window.removeEventListener('resize', applyFooterHeight);
      if (ro) ro.disconnect();
    };
  }, []);

  return (
    <div ref={rootRef}>
      <Layout title={siteConfig.title} description={siteConfig.tagline}>
        <Head>
          <meta property="og:title" content={siteConfig.title} />
          <meta property="og:description" content={siteConfig.tagline} />
          <meta name="twitter:card" content="summary_large_image" />
        </Head>

        <HomepageHeader />
      </Layout>
    </div>
  );
}