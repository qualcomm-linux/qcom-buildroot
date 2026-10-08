// Shared ReadTheDocs-style nav/theme runtime for build/docs/.
// Pure core (below) is node-testable; browser bootstrap is added in Task 2.
(function (root) {
  'use strict';

  var NAV = [
    { id: 'index',   file: 'index.html',          title: 'Home',                  subtitle: 'Overview' },
    { id: 'why',     file: 'why.html',            title: 'Why this Build System', subtitle: 'Rationale' },
    { id: 'quick',   file: 'quick-start.html',    title: 'Quick Start',           subtitle: 'init · sync · build · flash' },
    { id: 'focused', file: 'lemans-focused.html', title: 'Lemans — Focused',      subtitle: 'Platform · Boot · Projects' },
    { id: 'full',    file: 'lemans.html',         title: 'Lemans — Comprehensive', subtitle: 'Build System Deep Dive' },
  ];

  function basename(path) {
    if (!path) return 'index.html';
    var cleaned = String(path).split('?')[0].split('#')[0];
    if (cleaned === '/' || cleaned.slice(-1) === '/') return 'index.html';
    var seg = cleaned.split('/').filter(Boolean).pop();
    return (seg || 'index.html').toLowerCase();
  }

  function currentIndex(nav, path) {
    var b = basename(path);
    for (var i = 0; i < nav.length; i++) {
      if (nav[i].file.toLowerCase() === b) return i;
    }
    return -1;
  }

  function breadcrumbFor(nav, path) {
    var crumbs = [{ title: 'Docs', href: 'index.html' }];
    var i = currentIndex(nav, path);
    if (i > 0) crumbs.push({ title: nav[i].title, href: nav[i].file });
    return crumbs;
  }

  function prevNextFor(nav, path) {
    var i = currentIndex(nav, path);
    if (i < 0) return { prev: null, next: null };
    return {
      prev: i > 0 ? nav[i - 1] : null,
      next: i < nav.length - 1 ? nav[i + 1] : null,
    };
  }

  var api = { NAV: NAV, basename: basename, currentIndex: currentIndex,
              breadcrumbFor: breadcrumbFor, prevNextFor: prevNextFor };

  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  root.RTD = api;

  // ---- Browser bootstrap (no-op in node / on non-rtd pages) ----
  if (typeof document === 'undefined') return;

  function el(tag, cls, html) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (html != null) e.innerHTML = html;
    return e;
  }

  function buildSidebar(path) {
    var side = el('nav', 'rtd-side');
    var head = el('div', 'rtd-side-head',
      '<a href="index.html">OP-TEE · Lemans EVK<span class="sub">SA8775P / QCS9075</span></a>');
    side.appendChild(head);
    var ul = el('ul');
    var curIdx = api.currentIndex(api.NAV, path);
    api.NAV.forEach(function (item, i) {
      var li = el('li');
      if (i === curIdx) li.className = 'current';
      li.appendChild(el('a', null,
        item.title + (item.subtitle ? '<span class="sub">' + item.subtitle + '</span>' : '')));
      li.firstChild.setAttribute('href', item.file);
      ul.appendChild(li);
      // in-page section sub-nav for the current deck/article page
      if (i === curIdx) {
        var subs = document.querySelectorAll('main.rtd-doc [data-sec]');
        if (subs.length) {
          var sub = el('ul', 'rtd-subnav');
          subs.forEach(function (s) {
            var a = el('a', null, s.getAttribute('data-sec-title') || s.id);
            a.setAttribute('href', '#' + s.id);
            var sli = el('li'); sli.appendChild(a); sub.appendChild(sli);
          });
          li.appendChild(sub);
        }
      }
    });
    side.appendChild(ul);
    return side;
  }

  function buildBreadcrumb(path) {
    var bc = el('div', 'rtd-breadcrumb');
    var trail = api.breadcrumbFor(api.NAV, path);
    trail.forEach(function (c, i) {
      if (i) bc.appendChild(el('span', 'sep', '»'));
      var a = el('a', null, c.title); a.setAttribute('href', c.href);
      bc.appendChild(a);
    });
    return bc;
  }

  function buildPrevNext(path) {
    var pn = api.prevNextFor(api.NAV, path);
    var f = el('footer', 'rtd-prevnext');
    if (pn.prev) { var p = el('a', null, '← ' + pn.prev.title); p.setAttribute('href', pn.prev.file); f.appendChild(p); }
    f.appendChild(el('span', 'spacer'));
    if (pn.next) { var n = el('a', null, pn.next.title + ' →'); n.setAttribute('href', pn.next.file); f.appendChild(n); }
    return f;
  }

  function addAnchors(main) {
    main.querySelectorAll('h1[id], h2[id], h3[id]').forEach(function (h) {
      var a = el('a', 'rtd-anchor', '¶'); a.setAttribute('href', '#' + h.id);
      h.appendChild(a);
    });
  }

  function boot() {
    if (!document.body.classList.contains('rtd')) return;
    var main = document.querySelector('main.rtd-doc');
    if (!main) return;
    var path = location.pathname || '';
    document.body.insertBefore(buildSidebar(path), document.body.firstChild);
    main.insertBefore(buildBreadcrumb(path), main.firstChild);
    main.appendChild(buildPrevNext(path));
    addAnchors(main);
    var logo = el('a', 'rtd-logo',
      '<img class="mark" src="assets/qualcomm-mark.svg" alt="">' +
      '<img class="word" src="img/qualcomm-logo.svg" alt="Qualcomm">');
    logo.setAttribute('href', 'https://www.qualcomm.com');
    logo.setAttribute('target', '_blank');
    logo.setAttribute('rel', 'noopener');
    document.body.appendChild(logo);
  }

  if (document.readyState === 'loading')
    document.addEventListener('DOMContentLoaded', boot);
  else boot();

  function bootDeck() {
    if (!document.body.classList.contains('rtd')) return;
    if (!document.body.hasAttribute('data-deck')) return;
    var btn = el('button', 'rtd-present-btn', '▶ Present');
    document.body.appendChild(btn);
    function enter() {
      document.body.classList.add('presenting');
      btn.innerHTML = '✕ Exit';
      if (typeof window.__deckGo === 'function') window.__deckGo(window.__deckCur || 0);
    }
    function exit() {
      document.body.classList.remove('presenting');
      btn.innerHTML = '▶ Present';
      window.location.href = 'index.html';
    }
    btn.addEventListener('click', function () {
      if (document.body.classList.contains('presenting')) exit();
      else enter();
    });
    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape' && document.body.classList.contains('presenting')) exit();
    });
  }
  if (document.readyState === 'loading')
    document.addEventListener('DOMContentLoaded', bootDeck);
  else bootDeck();
})(typeof window !== 'undefined' ? window : globalThis);
