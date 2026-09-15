import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import { test } from 'node:test';

function qmlFunction(file, name) {
  const source = readFileSync(new URL('../' + file, import.meta.url), 'utf8');
  const declaration = source.match(new RegExp('  function ' + name + '\\([^]*?\\n  \\}'));
  assert.ok(declaration, file + ' defines ' + name);
  return vm.runInNewContext(declaration[0] + '\n' + name);
}

const lookupSettings = qmlFunction('ShellSettings.qml', 'lookupSettings');
const fromUrl = qmlFunction('LocalPath.qml', 'fromUrl');
const versionFor = qmlFunction('ServiceVersion.qml', 'versionFor');
const id = 'matjam.omawall';
const entry = { id, folder: '/wallpapers', autoTheme: true };

for (const section of ['left', 'center', 'right']) {
  test('reads wallpaper settings from the ' + section + ' bar section', () => {
    const settings = lookupSettings({ bar: { layout: { [section]: [entry] } } }, id);
    assert.equal(settings.folder, '/wallpapers');
    assert.equal(settings.autoTheme, true);
  });
}

test('reads service-only settings and preserves bar precedence', () => {
  const service = { id, folder: '/service-only' };
  assert.equal(lookupSettings({ plugins: [service] }, id).folder, '/service-only');
  assert.equal(lookupSettings({
    bar: { layout: { center: [entry] } }, plugins: [service],
  }, id).folder, '/wallpapers');
});

test('resolves settings again after a configuration replacement', () => {
  assert.equal(lookupSettings({ plugins: [entry] }, id).folder, '/wallpapers');
  assert.equal(lookupSettings({ plugins: [{ id, folder: '/new-folder' }] }, id).folder, '/new-folder');
  assert.equal(lookupSettings({ plugins: [] }, id), null);
});

test('handles missing configuration and ignores other plugins', () => {
  assert.equal(lookupSettings(null, id), null);
  assert.equal(lookupSettings({ plugins: [{ id: 'another.plugin' }] }, id), null);
});

test('decodes bundled local paths without private manifest fields', () => {
  assert.equal(fromUrl('file:///plugins/my%20wallpapers/bin/tool%25%23'), '/plugins/my wallpapers/bin/tool%#');
  assert.equal(fromUrl('https://example.test/a%20b'), 'https://example.test/a%20b');
});

test('reads the version through the public service API', () => {
  assert.equal(versionFor(null, id), '');
  assert.equal(versionFor({ serviceFor: () => null }, id), '');
  assert.equal(versionFor({ serviceFor(requested) {
    assert.equal(requested, id);
    return { manifest: { version: '1.4.0' } };
  } }, id), '1.4.0');
});
