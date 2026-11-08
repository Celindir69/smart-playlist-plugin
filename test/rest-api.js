'use strict';
// Tests of the REST API (restApi) for other frontends: node test/rest-api.js
// Runs in a temporary folder with a stand-in for mpc; touches no real /data.
var assert = require('assert');
var fs = require('fs-extra');
var os = require('os');
var path = require('path');

var root = fs.mkdtempSync(path.join(os.tmpdir(), 'sp-test-'));
process.env.SMART_PLAYLISTS_TEST_ROOT = root;

// a tiny library and an mpc that answers like MPD for it
var music = path.join(root, 'music');
var bin = path.join(root, 'bin');
var tracks = [
  ['INTERNAL/Genesis/Duke/01.flac', 'Genesis', 'Genesis', 'Behind the Lines', 'Duke', 'Rock', '1980', '', '', '1', '300'],
  ['INTERNAL/Genesis/Live/01.flac', 'Genesis', 'Genesis', 'Turn It On', 'Three Sides Live', 'Rock', '1982', '', '', '1', '280'],
  ['INTERNAL/Supertramp/Breakfast/01.flac', 'Supertramp', 'Supertramp', 'Gone Hollywood', 'Breakfast in America', 'Rock', '1979', '', '', '1', '320']
];
tracks.forEach(function (t) { fs.outputFileSync(path.join(music, t[0]), 'x'); });
fs.outputFileSync(path.join(root, 'mpc.txt'), tracks.map(function (t) { return t.join('\x1f'); }).join('\n') + '\n');
fs.outputFileSync(path.join(bin, 'mpc'), '#!/bin/bash\n[ "$1" = stats ] && exit 0\ncat "' + path.join(root, 'mpc.txt') + '"\n', { mode: 0o755 });
process.env.PATH = bin + ':' + process.env.PATH;
process.env.SMART_PLAYLISTS_MPD_MUSIC_DIR = music;

var Controller = require('../index.js');
var h = Controller.helpers;

// --- helpers, same rules as the core script
assert.strictEqual(h.sanitizeName('AC/DC: Best?'), 'AC_DC_ Best_');
assert.strictEqual(h.sanitizeName('.hidden'), '_.hidden');
assert.strictEqual(h.sanitizeName('  a   b '), 'a b');
assert.strictEqual(h.playlistOf('Rock 70s :: Genesis;Supertramp|year>=1970'), 'Rock 70s');
assert.strictEqual(h.playlistOf('Genesis;Supertramp|album!~Live'), 'Genesis, Supertramp|album!~Live');
assert.strictEqual(h.checkLine('Genesis'), 'no_name');
assert.strictEqual(h.checkLine('# x::Genesis'), 'bad_line');
assert.strictEqual(h.checkLine('A::|year>1'), 'bad_line');
assert.strictEqual(h.checkLine('A::Genesis\nB::x'), 'bad_line');
assert.strictEqual(h.checkLine('A::*|year>1970'), '');

// --- a controller with an in-memory config
function fakeConfig(values) {
  return { get: function (k) { return values[k]; }, set: function (k, v) { values[k] = v; } };
}
var values = { rule_1: '# example comment', rule_2: 'Old::Genesis' };
var c = new Controller({ coreCommand: { pushToastMessage: function () {} }, logger: { info: function () {}, error: function () {} }, configManager: {} });
c.config = fakeConfig(values);
var runs = 0;
c.executeScript = function () { runs++; return require('kew').resolve(); };

function call(data) { return new Promise(function (ok) { c.restApi(data).then(ok); }); }
var dataDir = path.join(root, 'data/smart_playlists_data');
var plDir = path.join(root, 'data/playlist');

call({ action: 'list' })
  .then(function (r) {
    assert.strictEqual(r.ok, true);
    assert.strictEqual(r.api, 1);
    assert.deepStrictEqual(r.rules.map(function (x) { return [x.slot, x.name, x.playlist, x.created]; }), [[2, 'Old', 'Old', false]]);
    return call({ action: 'save', line: 'Genesis Mix::Genesis' });
  })
  .then(function (r) {
    assert.deepStrictEqual(r, { ok: true, slot: 3, playlist: 'Genesis Mix' });   // comment line 1 stays
    assert.strictEqual(values.rule_3, 'Genesis Mix::Genesis');
    assert.ok(fs.readFileSync(path.join(dataDir, 'smart_playlists.txt'), 'utf8').indexOf('Genesis Mix::Genesis') >= 0);
    return call({ action: 'save', line: 'genesis mix::Genesis', slot: 0 }).then(function (r2) {
      assert.strictEqual(r2.ok, true);   // other case = other file name
      return call({ action: 'save', line: 'Genesis Mix::Supertramp' });
    });
  })
  .then(function (r) {
    assert.deepStrictEqual(r, { ok: false, error: 'name_taken' });
    return call({ action: 'save', slot: 3, line: 'Genesis Mix::Genesis|album!~Live' });   // the same rule again: fine
  })
  .then(function (r) {
    assert.deepStrictEqual(r, { ok: true, slot: 3, playlist: 'Genesis Mix' });
    assert.ok(runs >= 1);
    return call({ action: 'save', slot: 95, line: 'X::Y' });
  })
  .then(function (r) {
    assert.deepStrictEqual(r, { ok: false, error: 'bad_slot' });
    // as after a run: playlist file and manifest
    fs.outputFileSync(path.join(plDir, 'Genesis Mix'), '[]');
    fs.outputFileSync(path.join(plDir, 'Not mine'), '[]');
    fs.outputFileSync(path.join(dataDir, '.smart_playlists_manifest.tsv'), 'Old\nGenesis Mix\n');
    return call({ action: 'list' });
  })
  .then(function (r) {
    assert.strictEqual(r.rules.filter(function (x) { return x.slot === 3; })[0].created, true);
    return call({ action: 'delete', slot: 3 });
  })
  .then(function (r) {
    assert.deepStrictEqual(r, { ok: true });
    assert.strictEqual(values.rule_3, '');
    assert.ok(!fs.existsSync(path.join(plDir, 'Genesis Mix')));
    assert.ok(fs.existsSync(path.join(plDir, 'Not mine')));
    assert.strictEqual(fs.readFileSync(path.join(dataDir, '.smart_playlists_manifest.tsv'), 'utf8'), 'Old\n');
    return call({ action: 'delete', slot: 1 });   // a comment is no rule
  })
  .then(function (r) {
    assert.deepStrictEqual(r, { ok: false, error: 'bad_slot' });
    c.running = true;
    var before = runs;
    var r2 = c.apiRun();
    assert.strictEqual(c.rerunWanted, true);
    assert.strictEqual(runs, before);
    c.running = false;
    c.rerunWanted = false;
    assert.ok(r2.ok);
    return call({ action: 'nope' });
  })
  .then(function (r) {
    assert.deepStrictEqual(r, { ok: false, error: 'bad_action' });
    return call({ action: 'preview', line: 'Genesis|album!~Live' });   // name is added for the preview
  })
  .then(function (r) {
    assert.strictEqual(r.ok, true, JSON.stringify(r));
    assert.strictEqual(r.count, 1);
    assert.deepStrictEqual(r.tracks, [{ title: 'Behind the Lines', artist: 'Genesis', album: 'Duke' }]);
    return call({ action: 'preview', line: 'P::Nobody' });
  })
  .then(function (r) {
    assert.deepStrictEqual(r, { ok: true, count: 0, tracks: [] });
    assert.ok(!fs.existsSync(path.join(plDir, 'P')));   // the preview writes no real playlist
    fs.removeSync(root);
    console.log('rest-api: all tests passed');
  })
  .catch(function (err) {
    fs.removeSync(root);
    console.error(err);
    process.exit(1);
  });
