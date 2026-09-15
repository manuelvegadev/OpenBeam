import { defineConfig } from 'rspress/config';

export default defineConfig({
  root: 'docs',
  // The site is served from a project page, so every asset and link is
  // prefixed. The landing page sits at /OpenBeam/ and these docs below it.
  base: '/OpenBeam/docs/',
  outDir: 'dist',
  title: 'OpenBeam',
  description: 'Send a webcam over NDI, and turn NDI back into a webcam.',
  icon: '/favicon.png',
  logo: '/logo.png',
  logoText: 'OpenBeam',
  themeConfig: {
    outlineTitle: 'On this page',
    lastUpdated: true,
    socialLinks: [
      {
        icon: 'github',
        mode: 'link',
        content: 'https://github.com/manuelvegadev/OpenBeam',
      },
    ],
    nav: [
      { text: 'Guide', link: '/' },
      { text: 'Download', link: 'https://github.com/manuelvegadev/OpenBeam/releases' },
    ],
    sidebar: {
      '/': [
        {
          text: 'Get started',
          items: [
            { text: 'Install and first send', link: '/' },
          ],
        },
        {
          text: 'Guides',
          items: [
            { text: 'Send and receive', link: '/guides/send-receive' },
            { text: 'Clipboard sync', link: '/guides/clipboard-sync' },
            { text: 'Updating', link: '/guides/updating' },
          ],
        },
        {
          text: 'Reference',
          items: [
            { text: 'Settings', link: '/reference/settings' },
            { text: 'Requirements', link: '/reference/requirements' },
          ],
        },
        {
          text: 'Help',
          items: [
            { text: 'Troubleshooting', link: '/troubleshooting' },
          ],
        },
      ],
    },
  },
});
