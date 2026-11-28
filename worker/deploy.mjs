// ينشئ مخزن KV إذا مو موجود، ينقل المكتبة من GitHub أول مرة، وينشر السيرفر.
import { execSync } from 'node:child_process';
import { readFileSync, writeFileSync } from 'node:fs';

const token = process.env.CLOUDFLARE_API_TOKEN;
const account = process.env.CLOUDFLARE_ACCOUNT_ID;
if (!token || !account) throw new Error('CLOUDFLARE_API_TOKEN / CLOUDFLARE_ACCOUNT_ID missing');
const api = `https://api.cloudflare.com/client/v4/accounts/${account}`;
const headers = { Authorization: `Bearer ${token}` };

async function cf(path, init = {}) {
  const res = await fetch(api + path, { ...init, headers: { ...headers, ...(init.headers || {}) } });
  const body = await res.json().catch(() => ({}));
  if (!res.ok || body.success === false) throw new Error(`${path}: ${res.status} ${JSON.stringify(body.errors || body)}`);
  return body.result;
}

// 1) مخزن KV
const spaces = await cf('/storage/kv/namespaces?per_page=100');
let ns = spaces.find((s) => s.title === 'rawsam-data');
if (!ns) ns = await cf('/storage/kv/namespaces', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ title: 'rawsam-data' }) });
console.log('KV namespace ready');

const kv = `/storage/kv/namespaces/${ns.id}`;
async function kvGet(key) {
  const res = await fetch(`${api}${kv}/values/${encodeURIComponent(key)}`, { headers });
  return res.status === 200 ? res : null;
}
async function kvPut(key, body, metadata) {
  const form = new FormData();
  form.append('value', new Blob([body]));
  form.append('metadata', JSON.stringify(metadata || {}));
  await cf(`${kv}/values/${encodeURIComponent(key)}`, { method: 'PUT', body: form });
}

// 2) النقل من GitHub (مرة وحدة بس)
if (!(await kvGet('config'))) {
  const raw = 'https://raw.githubusercontent.com/husainalkhazraji-crypto/Rawsam-printer/library/';
  const config = await (await fetch(raw + 'config.json')).json();
  const files = new Set();
  for (const list of [config.banners, config.editorBanners, config.settingsBanners]) for (const i of list || []) files.add(i.file);
  for (const c of config.categories || []) for (const i of c.items || []) files.add(i.file);
  let n = 0;
  for (const f of files) {
    const res = await fetch(raw + 'files/' + f);
    if (!res.ok) { console.log('skip missing', f); continue; }
    await kvPut('file:' + f, new Uint8Array(await res.arrayBuffer()), { type: 'image/jpeg' });
    n++;
  }
  const admin = { passwordHash: config.passwordHash };
  delete config.passwordHash;
  await kvPut('admin', JSON.stringify(admin));
  await kvPut('config', JSON.stringify(config));
  console.log(`migrated ${n} images and settings from GitHub`);
} else {
  console.log('library already on Cloudflare');
}

// 3) النشر
writeFileSync('wrangler.toml', readFileSync('wrangler.template.toml', 'utf8').replace('__KV_ID__', ns.id));
execSync('npx --yes wrangler@3 deploy', { stdio: 'inherit' });
const sub = await cf('/workers/subdomain').catch(() => null);
console.log('WORKER_URL=https://rawsam.' + (sub?.subdomain || '?') + '.workers.dev');

// 4) فحص سريع بعد النشر
const base = 'https://rawsam.' + (sub?.subdomain || '') + '.workers.dev';
await new Promise((r) => setTimeout(r, 5000));
const check = async (label, fn) => { try { console.log('CHECK', label, await fn()); } catch (e) { console.log('CHECK', label, 'FAILED', e.message); } };
const cfg = await (await fetch(base + '/config')).json();
await check('config', async () => `categories=${cfg.categories?.length} banners=${cfg.banners?.length} hasPassword=${'passwordHash' in cfg}`);
const first = cfg.banners?.[0]?.file || cfg.categories?.find((c) => c.items.length)?.items[0]?.file;
await check('image', async () => { const r = await fetch(base + '/files/' + first); return `${r.status} ${r.headers.get('content-type')} ${(await r.arrayBuffer()).byteLength} bytes`; });
await check('admin without login', async () => (await fetch(base + '/admin/messages')).status);
await check('wrong password', async () => (await fetch(base + '/admin/login', { method: 'POST', body: JSON.stringify({ password: 'wrong-test' }) })).status);
await check('long message rejected', async () => (await fetch(base + '/messages', { method: 'POST', body: JSON.stringify({ text: 'x'.repeat(301), device: 'ci-test' }) })).status);
