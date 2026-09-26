// JSON API client: same-origin fetch, CSRF header on POST, global 401 handling.

let csrfToken = '';

export function setCsrf(t) { csrfToken = t || ''; }

export class ApiError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

async function request(method, path, body) {
  const opts = {
    method,
    credentials: 'same-origin',
    cache: 'no-store',
    headers: { Accept: 'application/json' },
  };
  if (method !== 'GET') {
    opts.headers['X-CSRF-Token'] = csrfToken;
    opts.headers['Content-Type'] = 'application/json';
    opts.body = JSON.stringify(body === undefined ? {} : body);
  }
  let res;
  try {
    res = await fetch(path, opts);
  } catch {
    throw new ApiError(0, '网络错误：无法连接管理面板，请检查网络或 VPN');
  }
  let data = null;
  try { data = await res.json(); } catch { /* not JSON */ }
  if (res.status === 401 && !path.startsWith('/api/auth/') && path !== '/api/me') {
    window.dispatchEvent(new CustomEvent('hv:unauthorized'));
  }
  if (!res.ok) {
    throw new ApiError(res.status, (data && data.error) || `请求失败（HTTP ${res.status}）`);
  }
  return data;
}

export const api = {
  get: (path) => request('GET', path),
  post: (path, body) => request('POST', path, body),
};

export function qs(params) {
  const u = new URLSearchParams();
  for (const [k, v] of Object.entries(params)) {
    if (v !== undefined && v !== null && v !== '') u.set(k, String(v));
  }
  const s = u.toString();
  return s ? '?' + s : '';
}
