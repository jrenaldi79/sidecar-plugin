// wrapper.mjs — proxy-aware entry point for anthropic-proxy.
//
// Why this exists: Node's built-in fetch() (powered by undici) does NOT
// honor HTTP_PROXY/HTTPS_PROXY env vars by default. In sandboxed
// environments (Cowork, restricted Linux containers, corporate networks,
// etc.) where outbound traffic must go through a forward proxy, a bare
// fetch() call fails with EAI_AGAIN — the runtime can't even resolve DNS.
//
// This wrapper sets a global undici dispatcher BEFORE loading
// anthropic-proxy. When HTTPS_PROXY (or HTTP_PROXY) is set, every
// subsequent fetch() in the process tunnels through that proxy. When the
// env vars are unset (normal direct-internet environments), the dispatcher
// is a no-op and behavior is identical to before.
//
// Defensive: prefers undici.EnvHttpProxyAgent (added in undici 5.20.0,
// shipped with Node 18+/20+/22+) but falls back to ProxyAgent with an
// explicit URL if EnvHttpProxyAgent isn't in this build of undici.

import * as undici from 'undici';

const proxyUrl =
  process.env.HTTPS_PROXY ||
  process.env.https_proxy ||
  process.env.HTTP_PROXY ||
  process.env.http_proxy ||
  '';

if (proxyUrl) {
  let dispatcher;
  if (typeof undici.EnvHttpProxyAgent === 'function') {
    dispatcher = new undici.EnvHttpProxyAgent();
  } else if (typeof undici.ProxyAgent === 'function') {
    dispatcher = new undici.ProxyAgent(proxyUrl);
  }
  if (dispatcher && typeof undici.setGlobalDispatcher === 'function') {
    undici.setGlobalDispatcher(dispatcher);
    // eslint-disable-next-line no-console
    console.log(`[sidecar] global fetch dispatcher set via ${dispatcher.constructor.name} -> ${proxyUrl}`);
  }
}

// Now load anthropic-proxy. Dynamic import ensures the dispatcher is set
// before anthropic-proxy's top-level code runs (which starts the Fastify
// server and registers fetch handlers).
import('anthropic-proxy/index.js').catch((err) => {
  // eslint-disable-next-line no-console
  console.error('[sidecar] failed to load anthropic-proxy:', err);
  process.exit(1);
});
