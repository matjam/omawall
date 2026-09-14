import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import { test } from 'node:test';

const source = readFileSync(new URL('../Background.qml', import.meta.url), 'utf8');
const lookup = source.match(/  function lookupSettings\(config, id\) \{[\s\S]*?\n  \}/)[0];
const binding = source.match(/readonly property var settings: (.*)/)[1];
const id = 'matjam.omawall';
const entry = { id, folder: '/wallpapers', autoTheme: true };

function settings(shell) {
  return vm.runInNewContext(`${lookup}\n${binding}`, { shell, pluginId: id });
}

test('reads the wallpaper folder from the current scoped shell API', () => {
  const shell = { barConfig: { layout: { right: [entry] } } };
  assert.equal(settings(shell).folder, '/wallpapers');
  assert.equal(settings(shell).autoTheme, true);
  shell.barConfig = { layout: { left: [{ id, folder: '/new-folder' }] } };
  assert.equal(settings(shell).folder, '/new-folder');
});

test('retains older shell settings and bar precedence', () => {
  const legacy = { id, folder: '/legacy' };
  assert.equal(settings({ shellConfig: { plugins: [legacy] } }).folder, '/legacy');
  assert.equal(settings({ shellConfig: {
    bar: { layout: { center: [entry] } }, plugins: [legacy],
  } }).folder, '/wallpapers');
});

test('handles startup before the shell is injected', () => {
  assert.equal(settings(null).folder, undefined);
});

test('finds bundled scripts without private manifest fields', () => {
  const expression = source.match(/readonly property string sourceDir: (.*)/)[1];
  const path = vm.runInNewContext(expression, {
    manifest: { id },
    Qt: { resolvedUrl: () => 'file:///plugins/my%20wallpapers/' },
  });
  assert.equal(path, '/plugins/my wallpapers');
});
