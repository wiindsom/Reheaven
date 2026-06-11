import { themes as prismThemes } from 'prism-react-renderer';
import type { Config } from '@docusaurus/types';
import type * as Preset from '@docusaurus/preset-classic';
// This runs in Node.js - Don't use client-side code here (browser APIs, JSX...)

const config: Config = {
    title: 'Reheaven',
    tagline: "Ascend your game's state management.",
    favicon: 'img/reheaven_logo.svg',

    headTags: [
        {
            tagName: 'meta',
            attributes: {
                property: 'og:site_name',
                content: 'wiindsom',
            },
        },
        {
            tagName: 'meta',
            attributes: {
                name: 'theme-color',
                content: '#a676dd',
            },
        },
    ],

    // Future flags, see https://docusaurus.io/docs/api/docusaurus-config#future
    future: {
        v4: true, // Improve compatibility with the upcoming Docusaurus v4
    },

    // Set the production url of your site here
    url: 'https://arc.is-a.dev',
    // Set the /<baseUrl>/ pathname under which your site is served
    // For GitHub pages deployment, it is often '/<projectName>/'
    baseUrl: '/Reheaven/',

    // GitHub pages deployment config.
    // If you aren't using GitHub pages, you don't need these.
    organizationName: 'wiindsom', // Usually your GitHub org/user name.
    projectName: 'Reheaven', // Usually your repo name.

    onBrokenLinks: 'throw',

    // Even if you don't use internationalization, you can use this field to set
    // useful metadata like html lang. For example, if your site is Chinese, you
    // may want to replace "en" with "zh-Hans".
    i18n: {
        defaultLocale: 'en',
        locales: ['en'],
    },

    presets: [
        [
            'classic',
            {
                docs: {
                    sidebarPath: './sidebars.ts',
                },
                theme: {
                    customCss: './src/css/custom.css',
                },
            } satisfies Preset.Options,
        ],
    ],

    plugins: [
        [
            '@docusaurus/plugin-content-docs',
            {
                id: 'changelog',
                path: 'changelog',
                routeBasePath: 'changelog',
                sidebarPath: './sidebarsChangelog.ts',
            },
        ],
    ],

    themeConfig: {
        // Replace with your project's social card
        image: 'img/reheaven_socialcard.png',
        colorMode: {
            defaultMode: "dark",
            respectPrefersColorScheme: false,
        },
        navbar: {
            logo: {
                alt: 'Reheaven',
                src: 'img/reheaven_navbrand.svg',
            },
            items: [
                {
                    type: 'docSidebar',
                    sidebarId: 'docsSidebar',
                    position: 'left',
                    label: 'Documentation',
                },
                {
                    type: 'docSidebar',
                    docsPluginId: 'changelog',
                    sidebarId: 'changelogSidebar',
                    position: 'left',
                    label: 'Changelog',
                },
                {
                    href: 'https://devforum.roblox.com',
                    label: 'DevForum',
                    position: 'right',
                },
                {
                    href: 'https://github.com/wiindsom/Reheaven',
                    label: 'GitHub',
                    position: 'right',
                },
            ],
        },
        footer: {
            style: 'dark',
            copyright: `© ${new Date().getFullYear()} Reheaven · Created by <a href="https://github.com/wiindsom" target="_blank" rel="noopener noreferrer">wiindsom</a> · MIT Licensed`,
        },
        prism: {
            theme: prismThemes.oneLight,
            darkTheme: prismThemes.oneDark,
            additionalLanguages: ['lua']
        },
    } satisfies Preset.ThemeConfig,
};

export default config;
