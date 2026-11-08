'use strict';
// Tests of the rules history (lost settings after an uninstall/update): node test/rules-history.js
// Runs in a temporary folder; touches no real /data.
var assert = require('assert');
var fs = require('fs-extra');
var os = require('os');
var path = require('path');

var root = fs.mkdtempSync(path.join(os.tmpdir(), 'sp-hist-'));
process.env.SMART_PLAYLISTS_TEST_ROOT = root;
var Controller = require('../index.js');
var dataDir = path.join(root, 'data/smart_playlists_data');
var histDir = path.join(dataDir, 'history');
var rulesFile = path.join(dataDir, 'smart_playlists.txt');
var EXAMPLES = { rule_1: '# One playlist rule per line. Examples:', rule_2: '# Genesis;Supertramp' };

function controller(values) {
  var c = new Controller({ coreCommand: { pushToastMessage: function () {} }, logger: { info: function () {}, error: function () {} }, configManager: {} });
  c.config = { get: function (k) { return values[k]; }, set: function (k, v) { values[k] = v; } };
  return c;
}
function p(kewPromise) { return new Promise(function (ok, bad) { kewPromise.then(ok, bad); }); }
function history() { return fs.existsSync(histDir) ? fs.readdirSync(histDir).filter(function (n) { return /^rules-/.test(n); }).sort(function (a, b) { var x = a.replace('.txt', '').split('-'), y = b.replace('.txt', '').split('-'); return (x[1] + x[2]).localeCompare(y[1] + y[2]) || (+(x[3] || 0)) - (+(y[3] || 0)); }) : []; }
function fresh() { fs.removeSync(dataDir); return Object.assign({}, EXAMPLES); }
var steps = [];
function t(name, fn) { steps.push([name, fn]); }

t('writing real rules keeps a version in the history, the same content only once', function () {
  var v = fresh(); v.rule_1 = 'Rock::Genesis';
  var c = controller(v);
  return p(c.writeRulesFile()).then(function () { return p(c.writeRulesFile()); }).then(function () {
    assert.strictEqual(history().length, 1);
    assert.ok(fs.readFileSync(path.join(histDir, history()[0]), 'utf8').indexOf('Rock::Genesis') >= 0);
    v.rule_2 = 'Pop::Abba';
    return p(c.writeRulesFile());
  }).then(function () {
    assert.strictEqual(history().length, 2);
  });
});

t('settings lost and the rules file only has the examples: the newest version comes back', function () {
  // as after the user's update: new install, examples in the config, examples in the file
  var v = Object.assign({}, EXAMPLES);
  fs.outputFileSync(rulesFile, '# One playlist rule per line. Examples:\n# Genesis;Supertramp\n');
  var c = controller(v);
  return p(c.reconcileRulesFile()).then(function () {
    assert.strictEqual(v.rule_1, 'Rock::Genesis');
    assert.strictEqual(v.rule_2, 'Pop::Abba');
    assert.ok(fs.readFileSync(rulesFile, 'utf8').indexOf('Pop::Abba') >= 0);
  });
});

t('rules emptied on purpose are not brought back', function () {
  var v = fresh(); v.rule_1 = 'Rock::Genesis';
  var c = controller(v);
  return p(c.writeRulesFile()).then(function () {
    v.rule_1 = '';
    return p(c.writeRulesFile());   // as a save with no rules left
  }).then(function () {
    assert.ok(fs.existsSync(path.join(histDir, 'cleared')));
    var v2 = Object.assign({}, EXAMPLES);
    return p(controller(v2).reconcileRulesFile()).then(function () {
      assert.strictEqual(v2.rule_1, EXAMPLES.rule_1);
    });
  }).then(function () {
    v.rule_1 = 'Jazz::Coltrane';   // real rules again: the marker goes
    return p(c.writeRulesFile());
  }).then(function () {
    assert.ok(!fs.existsSync(path.join(histDir, 'cleared')));
  });
});

t('no history yet (rules from before this version): the .bak of the rules file helps', function () {
  fresh();
  fs.outputFileSync(rulesFile + '.bak', 'Old::Genesis\n');
  fs.outputFileSync(rulesFile, '# examples only\n');
  var v = Object.assign({}, EXAMPLES);
  return p(controller(v).reconcileRulesFile()).then(function () {
    assert.strictEqual(v.rule_1, 'Old::Genesis');
    assert.strictEqual(history().length, 1);
  });
});

t('a rules file with real rules is still read in as before, and kept in the history', function () {
  fresh();
  fs.outputFileSync(rulesFile, 'File::Genesis\n');
  var v = Object.assign({}, EXAMPLES);
  return p(controller(v).reconcileRulesFile()).then(function () {
    assert.strictEqual(v.rule_1, 'File::Genesis');
    assert.strictEqual(history().length, 1);
  });
});

t('only the newest 20 versions are kept', function () {
  var v = fresh();
  var c = controller(v);
  var chain = Promise.resolve();
  for (var i = 0; i < 25; i++) {
    (function (n) { chain = chain.then(function () { v.rule_1 = 'R' + n + '::Genesis'; return p(c.writeRulesFile()); }); })(i);
  }
  return chain.then(function () {
    var h = history();
    assert.strictEqual(h.length, 20);
    assert.ok(fs.readFileSync(path.join(histDir, h[h.length - 1]), 'utf8').indexOf('R24::') === 0);
  });
});

t('fresh install without anything: nothing to restore', function () {
  fresh();
  var v = Object.assign({}, EXAMPLES);
  return p(controller(v).reconcileRulesFile()).then(function () {
    assert.strictEqual(v.rule_1, EXAMPLES.rule_1);
    assert.ok(!fs.existsSync(rulesFile));
  });
});

steps.reduce(function (chain, s) {
  return chain.then(function () { return s[1](); }).then(function () { console.log('ok   ' + s[0]); });
}, Promise.resolve()).then(function () {
  fs.removeSync(root);
  console.log('rules-history: all tests passed');
}).catch(function (err) {
  fs.removeSync(root);
  console.error(err);
  process.exit(1);
});
