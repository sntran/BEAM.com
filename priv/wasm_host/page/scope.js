// The rule of the scope of the frame of the app (app/ of the site). An app
// can write a path without its base path (href="/", or a redirect to "/").
// A URL of this origin outside the scope is such a path: it goes to the same
// path in the scope. sw.js applies it to a redirect, and ws-shim.js (a
// classic script, which cannot import this module) has a copy of it for the
// links and the forms.

// true: url (a URL) is of the origin of scope and outside it.
export function outside(url, scope) {
  return url.origin === scope.origin && !`${url.pathname}/`.startsWith(scope.pathname);
}

// The href of url in the scope: the same path, with the prefix of the scope.
export function inScope(url, scope) {
  if (!outside(url, scope)) return url.href;
  return new URL(scope.pathname.replace(/\/$/, '') + url.pathname + url.search + url.hash, url).href;
}
