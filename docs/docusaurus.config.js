'use strict';

// @ts-check
const config = {
  title: 'NeoRecall',
  tagline: 'Private, self-hosted audio memory',
  favicon: 'img/logo.svg',
  url: 'https://neolabs-systems.github.io',
  baseUrl: '/NeoRecall/docs/',
  organizationName: 'NeoLabs-Systems',
  projectName: 'NeoRecall',
  onBrokenLinks: 'throw',
  i18n: { defaultLocale: 'en', locales: ['en'] },
  presets: [['classic', {
    docs: { routeBasePath: '/', sidebarPath: require.resolve('./sidebars.js') },
    blog: false,
    theme: { customCss: require.resolve('./src/css/custom.css') },
  }]],
  themeConfig: {
    navbar: {
      title: 'NeoRecall',
      logo: { alt: 'NeoRecall', src: 'img/logo.svg' },
      items: [
        { type: 'doc', docId: 'installation', position: 'left', label: 'Docs' },
        { href: 'https://github.com/NeoLabs-Systems/NeoRecall', label: 'GitHub', position: 'right' },
      ],
    },
    footer: { style: 'dark', copyright: `Copyright ${new Date().getFullYear()} NeoLabs-Systems. AGPL-3.0.` },
  },
};

module.exports = config;
