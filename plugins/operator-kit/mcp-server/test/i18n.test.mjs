import test from 'node:test';
import assert from 'node:assert/strict';
import { resolveLocale, translate } from '../src/i18n.js';

test('explicit language overrides host; automatic language uses host, browser, then supported fallback', () => {
  assert.equal(resolveLocale('en', 'pl-PL'), 'en-US');
  assert.equal(resolveLocale('pl', 'en-US'), 'pl-PL');
  assert.equal(resolveLocale('auto', 'pl-PL', 'en-US'), 'pl-PL');
  assert.equal(resolveLocale('auto', undefined, 'pl'), 'pl-PL');
  assert.equal(resolveLocale('auto', 'de-DE'), 'en-US');
  assert.equal(resolveLocale('auto', 'not_valid'), 'en-US');
  assert.equal(translate('pl-PL', 'All projects'), 'Wszystkie projekty');
  assert.equal(translate('pl-PL', 'Customer-authored feature title'), 'Customer-authored feature title');
});
