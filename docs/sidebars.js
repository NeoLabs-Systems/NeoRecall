'use strict';

/** @type {import('@docusaurus/plugin-content-docs').SidebarsConfig} */
module.exports = {
  docsSidebar: [
    'index',
    {
      type: 'category',
      label: '🧭 User Guide',
      collapsed: false,
      items: ['installation', 'recording', 'configuration', 'privacy-and-consent', 'troubleshooting'],
    },
    {
      type: 'category',
      label: '🛠️ Developer Guide',
      collapsed: false,
      items: ['architecture'],
    },
  ],
};
