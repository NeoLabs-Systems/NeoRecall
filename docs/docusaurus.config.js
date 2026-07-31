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
        { type: 'docSidebar', sidebarId: 'docsSidebar', position: 'left', label: 'Docs' },
        { type: 'doc', docId: 'installation', label: 'User Guide', position: 'left' },
        { type: 'doc', docId: 'architecture', label: 'Developer Guide', position: 'left' },
        { href: 'https://github.com/NeoLabs-Systems/NeoRecall', label: 'GitHub', position: 'right' },
      ],
    },
    tableOfContents: { minHeadingLevel: 2, maxHeadingLevel: 3 },
    footer: {
      style: 'dark',
      links: [
        {
          title: 'Docs',
          items: [
            { label: 'Installation', to: '/installation' },
            { label: 'Recording', to: '/recording' },
            { label: 'Privacy and consent', to: '/privacy-and-consent' },
            { label: 'Configuration', to: '/configuration' },
          ],
        },
        {
          title: 'Developers',
          items: [{ label: 'Architecture', to: '/architecture' }],
        },
        {
          title: 'Project',
          items: [
            { label: 'GitHub', href: 'https://github.com/NeoLabs-Systems/NeoRecall' },
            { label: 'Issues', href: 'https://github.com/NeoLabs-Systems/NeoRecall/issues' },
            { label: 'Discussions', href: 'https://github.com/NeoLabs-Systems/NeoRecall/discussions' },
          ],
        },
      ],
      copyright: `Copyright ${new Date().getFullYear()} NeoLabs-Systems. AGPL-3.0.`,
    },
  },
};

module.exports = config;
