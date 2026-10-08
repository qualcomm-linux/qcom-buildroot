const assert = require('node:assert');
const { test } = require('node:test');
const rtd = require('./_rtd.js');

test('NAV is ordered and complete', () => {
  const files = rtd.NAV.map(n => n.file);
  assert.deepStrictEqual(files, [
    'index.html', 'why.html', 'quick-start.html',
    'lemans-focused.html', 'lemans.html',
  ]);
});

test('basename normalizes paths', () => {
  assert.strictEqual(rtd.basename('/a/b/why.html'), 'why.html');
  assert.strictEqual(rtd.basename('why.html'), 'why.html');
  assert.strictEqual(rtd.basename('/'), 'index.html');
  assert.strictEqual(rtd.basename(''), 'index.html');
  assert.strictEqual(rtd.basename('/docs/'), 'index.html');
});

test('currentIndex matches by basename, case-insensitive', () => {
  assert.strictEqual(rtd.currentIndex(rtd.NAV, '/x/WHY.HTML'), 1);
  assert.strictEqual(rtd.currentIndex(rtd.NAV, '/'), 0);
  assert.strictEqual(rtd.currentIndex(rtd.NAV, 'nope.html'), -1);
});

test('breadcrumbFor: index shows only Docs root', () => {
  assert.deepStrictEqual(rtd.breadcrumbFor(rtd.NAV, 'index.html'),
    [{ title: 'Docs', href: 'index.html' }]);
});

test('breadcrumbFor: leaf page appends its title', () => {
  const bc = rtd.breadcrumbFor(rtd.NAV, 'quick-start.html');
  assert.strictEqual(bc.length, 2);
  assert.deepStrictEqual(bc[0], { title: 'Docs', href: 'index.html' });
  assert.strictEqual(bc[1].href, 'quick-start.html');
  assert.strictEqual(typeof bc[1].title, 'string');
});

test('prevNextFor: ends are null, middle links both ways', () => {
  assert.strictEqual(rtd.prevNextFor(rtd.NAV, 'index.html').prev, null);
  assert.strictEqual(rtd.prevNextFor(rtd.NAV, 'lemans.html').next, null);
  const mid = rtd.prevNextFor(rtd.NAV, 'quick-start.html');
  assert.strictEqual(mid.prev.file, 'why.html');
  assert.strictEqual(mid.next.file, 'lemans-focused.html');
});
