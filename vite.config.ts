/**
 * Business responsibility: configure the Photon frontend build and expose the
 * deployment metadata that users see in version badges and update notes.
 */
import { sveltekit } from '@sveltejs/kit/vite'
import tailwindcss from '@tailwindcss/vite'
import { defineConfig } from 'vite'

const deployVersion =
  process.env.DEPLOY_VERSION ?? process.env.npm_package_version ?? '0.0.0'

export default defineConfig({
  plugins: [sveltekit(), tailwindcss()],
  build: {
    sourcemap: true,
  },
  define: {
    __VERSION__: JSON.stringify(deployVersion),
    __DEPLOY_COMMIT__: JSON.stringify(process.env.DEPLOY_COMMIT ?? ''),
    __DEPLOY_PREVIOUS_COMMIT__: JSON.stringify(
      process.env.DEPLOY_PREVIOUS_COMMIT ?? '',
    ),
    __DEPLOYED_AT__: JSON.stringify(process.env.DEPLOY_TIME ?? ''),
    __DEPLOY_NOTES__: JSON.stringify(process.env.DEPLOY_NOTES ?? ''),
  },
  server: {
    watch: {
      ignored: ['!**/node_modules/mono-svelte/**'],
    },
  },
})
