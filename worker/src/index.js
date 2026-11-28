// سيرفر Rawsam printer على Cloudflare Workers (مجاني).
// يخزن بـ KV: الإعدادات (config)، الصور (file:<name>)، رسائل المستخدمين (msg:<id>)، وبيانات المدير (admin).

const DAY = 86400;
const MESSAGE_TTL = 7 * DAY;      // الرسائل تنحذف وحدها بعد أسبوع
const MAX_TEXT = 300;
const MAX_CONTACT = 60;

const json = (data, status = 200, extra = {}) =>
  new Response(JSON.stringify(data), {
    status,
    headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store', ...extra },
  });
const fail = (message, status = 400) => json({ error: message }, status);

const enc = new TextEncoder();
const hex = (buf) => [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, '0')).join('');
const sha256 = async (text) => hex(await crypto.subtle.digest('SHA-256', enc.encode(text)));
const today = () => new Date().toISOString().slice(0, 10);

async function hmac(key, text) {
  const k = await crypto.subtle.importKey('raw', enc.encode(key), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  return hex(await crypto.subtle.sign('HMAC', k, enc.encode(text)));
}

async function adminRecord(env) {
  const rec = (await env.DATA.get('admin', 'json')) || {};
  if (!rec.sessionKey) {
    rec.sessionKey = hex(crypto.getRandomValues(new Uint8Array(32)));
    await env.DATA.put('admin', JSON.stringify(rec));
  }
  return rec;
}

async function isAdmin(request, env) {
  const token = (request.headers.get('authorization') || '').replace(/^Bearer\s+/i, '');
  const [expiry, sig] = token.split('.');
  if (!expiry || !sig || Number(expiry) < Date.now() / 1000) return false;
  const rec = await adminRecord(env);
  return (await hmac(rec.sessionKey + (rec.passwordHash || ''), expiry)) === sig;
}

async function limit(env, key, max, ttl) {
  const count = Number((await env.DATA.get(key)) || 0);
  if (count >= max) return false;
  await env.DATA.put(key, String(count + 1), { expirationTtl: ttl });
  return true;
}

function referenced(config) {
  const files = new Set();
  for (const list of [config.banners, config.editorBanners, config.settingsBanners]) for (const i of list || []) files.add(i.file);
  for (const c of config.categories || []) for (const i of c.items || []) files.add(i.file);
  return files;
}

async function listKeys(env, prefix) {
  const keys = [];
  let cursor;
  do {
    const page = await env.DATA.list({ prefix, cursor });
    keys.push(...page.keys);
    cursor = page.list_complete ? undefined : page.cursor;
  } while (cursor);
  return keys;
}

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const path = url.pathname;
    const method = request.method;
    const ip = request.headers.get('cf-connecting-ip') || 'unknown';

    if (method === 'OPTIONS') return new Response(null, { status: 204 });

    // ===== عام =====
    if (method === 'GET' && path === '/config') {
      const config = (await env.DATA.get('config', 'json')) || { version: 1, categories: [], banners: [] };
      delete config.passwordHash;
      return json(config);
    }

    if (method === 'GET' && path.startsWith('/files/')) {
      const name = decodeURIComponent(path.slice(7));
      const cache = caches.default;
      const hit = await cache.match(request);
      if (hit) return hit;
      const { value, metadata } = await env.DATA.getWithMetadata('file:' + name, 'arrayBuffer');
      if (!value) return new Response('not found', { status: 404 });
      const res = new Response(value, {
        headers: { 'content-type': metadata?.type || 'image/jpeg', 'cache-control': 'public, max-age=31536000, immutable' },
      });
      ctx.waitUntil(cache.put(request, res.clone()));
      return res;
    }

    if (method === 'POST' && path === '/messages') {
      let body;
      try { body = await request.json(); } catch { return fail('رسالة غير صالحة'); }
      const text = String(body.text || '').trim();
      const contact = String(body.contact || '').trim();
      const device = String(body.device || '').slice(0, 64);
      if (!text) return fail('اكتب الرسالة');
      if ([...text].length > MAX_TEXT) return fail(`الرسالة أطول من ${MAX_TEXT} حرف`);
      if ([...contact].length > MAX_CONTACT) return fail('الرقم أو الحساب طويل');
      if (!device) return fail('رسالة غير صالحة');
      const day = today();
      if (await env.DATA.get(`rl:dev:${device}:${day}`)) return fail('تگدر ترسل رسالة وحدة باليوم. جرّب باچر', 429);
      if (!(await limit(env, `rl:ip:${ip}:${day}`, 5, DAY))) return fail('وصلت الحد اليومي', 429);
      await env.DATA.put(`rl:dev:${device}:${day}`, '1', { expirationTtl: DAY });
      const id = `${Date.now()}-${hex(crypto.getRandomValues(new Uint8Array(4)))}`;
      // نخزن الرسالة بالـ metadata حتى نقراها كلها بطلب واحد.
      await env.DATA.put('msg:' + id, '', { expirationTtl: MESSAGE_TTL, metadata: { t: text, c: contact, d: Date.now() } });
      return json({ ok: true });
    }

    if (method === 'POST' && path === '/admin/login') {
      if (!(await limit(env, `rl:login:${ip}`, 10, 900))) return fail('محاولات كثيرة، انتظر ربع ساعة', 429);
      let body;
      try { body = await request.json(); } catch { return fail('طلب غير صالح'); }
      const rec = await adminRecord(env);
      if (!rec.passwordHash || (await sha256(String(body.password || ''))) !== rec.passwordHash) return fail('كلمة السر غلط', 401);
      const expiry = String(Math.floor(Date.now() / 1000) + 30 * DAY);
      return json({ token: `${expiry}.${await hmac(rec.sessionKey + rec.passwordHash, expiry)}` });
    }

    // ===== المدير =====
    if (path.startsWith('/admin/')) {
      if (!(await isAdmin(request, env))) return fail('لازم تدخل كمدير', 401);

      if (method === 'PUT' && path.startsWith('/admin/files/')) {
        const name = decodeURIComponent(path.slice(13));
        if (!/^[a-zA-Z0-9._-]{1,80}$/.test(name)) return fail('اسم ملف غير صالح');
        const data = await request.arrayBuffer();
        if (data.byteLength > 5 * 1024 * 1024) return fail('الصورة كبيرة (أكثر من 5 ميگا)');
        await env.DATA.put('file:' + name, data, { metadata: { type: request.headers.get('content-type') || 'image/jpeg' } });
        return json({ ok: true });
      }

      if (method === 'PUT' && path === '/admin/config') {
        let config;
        try { config = await request.json(); } catch { return fail('إعدادات غير صالحة'); }
        delete config.passwordHash;
        const existing = new Set((await listKeys(env, 'file:')).map((k) => k.name.slice(5)));
        // نشيل روابط الصور الي مو موجودة
        const ok = (i) => existing.has(i.file);
        for (const k of ['banners', 'editorBanners', 'settingsBanners']) if (config[k]) config[k] = config[k].filter(ok);
        for (const c of config.categories || []) c.items = (c.items || []).filter(ok);
        await env.DATA.put('config', JSON.stringify(config));
        // نحذف الصور الي ما عاد مستخدمة
        const used = referenced(config);
        const unused = [...existing].filter((f) => !used.has(f));
        await Promise.all(unused.map((f) => env.DATA.delete('file:' + f)));
        return json(config);
      }

      if (method === 'POST' && path === '/admin/password') {
        let body;
        try { body = await request.json(); } catch { return fail('طلب غير صالح'); }
        const password = String(body.password || '');
        if (password.length < 6) return fail('كلمة السر لازم 6 أحرف أو أكثر');
        const rec = await adminRecord(env);
        rec.passwordHash = await sha256(password);
        await env.DATA.put('admin', JSON.stringify(rec));
        const expiry = String(Math.floor(Date.now() / 1000) + 30 * DAY);
        return json({ token: `${expiry}.${await hmac(rec.sessionKey + rec.passwordHash, expiry)}` });
      }

      if (method === 'GET' && path === '/admin/messages') {
        const keys = await listKeys(env, 'msg:');
        const messages = keys
          .filter((k) => k.metadata)
          .map((k) => ({ id: k.name.slice(4), text: k.metadata.t, contact: k.metadata.c || null, date: k.metadata.d }))
          .sort((a, b) => b.date - a.date);
        return json(messages);
      }

      if (method === 'DELETE' && path.startsWith('/admin/messages/')) {
        await env.DATA.delete('msg:' + decodeURIComponent(path.slice(16)));
        return json({ ok: true });
      }
    }

    return fail('غير موجود', 404);
  },
};
