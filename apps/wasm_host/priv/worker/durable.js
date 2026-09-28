// The VM in one Durable Object, in place of one VM for each isolate: one
// instance for all the requests (a server whose state must be in one
// place), which runs all the time while it is in memory, and whose SQLite
// storage is the database of Ecto SQLite. All the requests go to the object
// "main" (BEAM_OBJECT names another one).
//
// Tenants: with the var BEAM_TENANTS, each tenant has its own object (its
// own VM, state and SQLite storage), and the request header x-beam-tenant
// gives its name to the app:
// - "cookie": GET /.tenant/NAME sets the cookie beam_tenant, and the cookie
//   names the object (for a workers.dev URL);
// - "host": the first label of the host names the object (NAME.example.com).
// A name has 1 to 32 characters: a-z, 0-9 and "-".
//
//   wrangler deploy -c wrangler.durable.jsonc
import { DurableObject } from 'cloudflare:workers';
import { Vm } from './worker.js';

export class Beam extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    this.vm = new Vm(env, { plain: false, sql: ctx.storage.sql, id: ctx.id.toString() });
  }

  fetch(request) {
    return this.vm.fetch(request);
  }
}

const valid = (name) => /^[a-z0-9-]{1,32}$/.test(name ?? '');

function tenant(request, env) {
  if (env.BEAM_TENANTS === 'host') return new URL(request.url).hostname.split('.')[0];
  if (env.BEAM_TENANTS === 'cookie') {
    const m = /(?:^|;\s*)beam_tenant=([^;]*)/.exec(request.headers.get('cookie') ?? '');
    return m?.[1];
  }
  return null;
}

export default {
  fetch(request, env) {
    const url = new URL(request.url);
    const set = env.BEAM_TENANTS === 'cookie' && /^\/\.tenant\/([^/]+)$/.exec(url.pathname);
    if (set) {
      if (!valid(set[1])) return new Response('bad tenant name\n', { status: 400 });
      return new Response(null, {
        status: 303,
        headers: { location: '/', 'set-cookie': `beam_tenant=${set[1]}; Path=/; Secure; HttpOnly; SameSite=Lax` },
      });
    }
    let name = env.BEAM_OBJECT ?? 'main';
    const t = tenant(request, env);
    if (t !== undefined && t !== null && !valid(t)) return new Response('bad tenant name\n', { status: 400 });
    name = t ?? name;
    // The app can trust the header: a client cannot give it.
    request = new Request(request);
    if (env.BEAM_TENANTS) request.headers.set('x-beam-tenant', name);
    else request.headers.delete('x-beam-tenant');
    return env.BEAM.get(env.BEAM.idFromName(name)).fetch(request);
  },
};
