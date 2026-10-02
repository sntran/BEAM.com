// The rule of the scope of the frame of the app (priv/wasm_host/page/scope.js):
// sw.js applies it to a redirect of the app.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { outside, inScope } from '../../priv/wasm_host/page/scope.js';

const scope = new URL('https://user.github.io/repo/app/');
const at = (path) => new URL(path, scope);

test('a path of the app stays as it is', () => {
  for (const path of ['/repo/app/', '/repo/app/users/log-in?a=1#b', '/repo/app']) {
    assert.equal(outside(at(path), scope), false, path);
    assert.equal(inScope(at(path), scope), at(path).href);
  }
});

test('a redirect to "/" goes to the home page of the app', () => {
  assert.equal(inScope(at('/'), scope), 'https://user.github.io/repo/app/');
});

test('a path outside the scope gets the prefix of the scope, with its query and fragment', () => {
  assert.equal(inScope(at('/users/log-in?return=1#top'), scope),
               'https://user.github.io/repo/app/users/log-in?return=1#top');
  assert.equal(inScope(at('/repo/apple'), scope), 'https://user.github.io/repo/app/repo/apple');
});

test('another origin stays as it is', () => {
  for (const href of ['https://example.com/', 'http://user.github.io/x', 'https://localhost/users']) {
    assert.equal(outside(new URL(href), scope), false, href);
    assert.equal(inScope(new URL(href), scope), new URL(href).href);
  }
});

test('a site at / of a custom domain', () => {
  const root = new URL('https://app.example.com/app/');
  assert.equal(inScope(new URL('https://app.example.com/'), root), 'https://app.example.com/app/');
  assert.equal(inScope(new URL('https://app.example.com/app/x'), root), 'https://app.example.com/app/x');
});
