import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import { test } from 'node:test';

const backgroundSource = readFileSync(new URL('../Background.qml', import.meta.url), 'utf8');

function backgroundIpcBlock() {
  const match = backgroundSource.match(/\n  ShellIpc \{\n    target: "background"\n[^]*?\n  \}/);
  assert.ok(match, 'Background.qml defines ShellIpc for target "background"');
  return match[0];
}

test('does not depend on removed ScreenMoveRemap type', () => {
  assert.doesNotMatch(backgroundSource, /\bScreenMoveRemap\b/);
  assert.doesNotMatch(backgroundSource, /\bremapGuard\b/);
});

test('tracks suspension state and binds wallpaper surface visibility to it', () => {
  assert.match(backgroundSource, /\n  property bool suspended: false\n/);
  assert.match(backgroundSource, /\n      visible: !root\.suspended\n/);
});

test('handles owed setSuspended IPC calls and reports suspended in status', () => {
  const ipc = backgroundIpcBlock();
  const fnMatch = ipc.match(/    function setSuspended\(value: string\): void \{([^]*?)\n    \}/);
  assert.ok(fnMatch, 'background ShellIpc defines setSuspended(value: string): void');

  const root = { suspended: false };
  const setSuspended = vm.runInNewContext(
    `(function setSuspended(value) {${fnMatch[1]}\n})`,
    { root },
  );

  setSuspended('true');
  assert.equal(root.suspended, true);

  setSuspended('false');
  assert.equal(root.suspended, false);

  setSuspended('1');
  assert.equal(root.suspended, false);

  setSuspended('');
  assert.equal(root.suspended, false);

  assert.match(ipc, /\bsuspended:\s*root\.suspended\b/);
});
