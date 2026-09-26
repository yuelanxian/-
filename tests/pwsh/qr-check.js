// Executes the rendered VPN QR page (tests/pwsh/unit.ps1 output) with a tiny fake DOM and checks
// that qrcode.js produced an SVG and that the embedded config round-trips exactly.
// Usage: node qr-check.js <vpn-qr.html> <expected.conf>
'use strict';
const fs = require('fs');
const vm = require('vm');

const html = fs.readFileSync(process.argv[2], 'utf8');
const expected = fs.readFileSync(process.argv[3], 'utf8');
const fail = (msg) => { console.log('  FAIL ' + msg); process.exit(1); };

const scripts = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map((m) => m[1]);
if (scripts.length !== 2) fail('expected 2 inline scripts, found ' + scripts.length);
if (/<script[^>]+src=/i.test(html)) fail('page must not load external scripts');

const els = {};
const el = (id) => els[id] || (els[id] = { id, innerHTML: '', className: 'hidden', textContent: '', onclick: null });
const ctx = {
  document: {
    getElementById: el,
    createElement: () => ({ click() {}, remove() {} }),
    body: { appendChild() {} },
  },
  URL: { createObjectURL: () => 'blob:test', revokeObjectURL() {} },
  Blob: function Blob(parts) { this.parts = parts; },
  setTimeout: () => 0,
};
vm.createContext(ctx);
try {
  vm.runInContext(scripts[0], ctx, { filename: 'qrcode.js' });
  vm.runInContext(scripts[1], ctx, { filename: 'page.js' });
} catch (e) {
  fail('page script threw: ' + e.message);
}
const svg = el('qr').innerHTML;
if (!svg.startsWith('<svg') || !svg.includes('<path d="M')) fail('no QR SVG rendered');
if (el('qr-error').className === 'err') fail('page reported a QR error');
if (el('conf').textContent !== expected) fail('embedded config differs from the expected text');
const count = (svg.match(/M\d+,\d+/g) || []).length;
if (count < 200) fail('suspiciously small QR (' + count + ' dark modules)');
console.log('  ok   QR page renders (' + count + ' dark modules), config round-trips');
