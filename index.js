'use strict';

var libQ = require('kew');
var fs = require('fs-extra');
var path = require('path');
var execFile = require('child_process').execFile;
var os = require('os');

// Must match the number of "rule_N" fields generated in config.json and
// UIConfig.json (single-line inputs, since Volumio's UI schema has no
// confirmed multi-line "textarea" element). Rules are grouped into three
// pages (1-30, 31-60, 61-90), each hidden behind its own
// "rules_page1_enabled"/"rules_page2_enabled"/"rules_page3_enabled"
// toggle switch (via UIConfig.json's "visibleIf", the same mechanism
// already used for schedule_time/schedule_enabled) so all three can be
// shown/hidden independently. Page 1 defaults to visible (existing users
// with <=30 rules see no change); pages 2/3 default to hidden.
var NUM_RULE_LINES = 90;

// Where the rules file, cache, manifest, and debug log live. Deliberately
// NOT inside the music folder (avoids accidental edits/deletion via
// Samba/file manager) and NOT inside the plugin's own install folder
// under /data/plugins/... (which gets wiped on plugin uninstall - and
// re-running "volumio plugin install" after "volumio plugin uninstall"
// for every update, rather than "volumio plugin refresh", is a common
// dev workflow). This path is untouched by either of those, so it
// survives both.
// TEST_ROOT only for test/rest-api.js, which must not touch a real /data.
var TEST_ROOT = process.env.SMART_PLAYLISTS_TEST_ROOT || '';
var PLUGIN_DATA_DIR = TEST_ROOT + '/data/smart_playlists_data';

// Up to 0.9.x the plugin was in the category user_interface, so Volumio kept
// its settings there. After the switch to miscellanea the new folder starts
// with the defaults; onStart takes the old settings over once.
var OLD_CONFIG_FILE = '/data/configuration/user_interface/smart_playlists/config.json';
// Volumio's playlist folder and the core script's list of the playlists it
// created (see smart-playlists-core.sh).
var PLAYLIST_DIR = TEST_ROOT + '/data/playlist';
var MANIFEST_NAME = '.smart_playlists_manifest.tsv';

// REST endpoint for other frontends such as Xplorio
// (POST /api/v1/pluginEndpoint with {"endpoint": "smart_playlists", "data": {...}}),
// see restApi() below.
var REST_ENDPOINT = {
  endpoint: 'smart_playlists',
  type: 'miscellanea',
  name: 'smart_playlists',
  method: 'restApi'
};
var API_VERSION = 1;
var MAX_RULE_LENGTH = 2000;
var PREVIEW_TIMEOUT_MS = 180 * 1000;

var MIGRATED_KEYS = /^(rule_\d+|rules_page\d_enabled|schedule_enabled|schedule_time)$/;

// A real rule: not empty and not a comment. The default config.json only
// holds commented examples, which must never count as the user's rules.
function isRuleLine(line) {
  var t = (line || '').trim();
  return t !== '' && t.charAt(0) !== '#';
}

module.exports = ControllerSmartPlaylists;

function ControllerSmartPlaylists(context) {
  var self = this;

  self.context = context;
  self.commandRouter = self.context.coreCommand;
  self.logger = self.context.logger;
  self.configManager = self.context.configManager;

  self.scheduleTimer = null;
  self.running = false; // a run (manual or scheduled) is in progress: no second one at the same time
  self.lastRun = null;   // {at, ok} of the last finished run, for the REST status
  self.rerunWanted = false;   // rules changed over REST during a run: run once more afterwards
  self.previewing = false;
  self.lastRunDate = null; // 'YYYY-MM-DD' of the last automatic run, to avoid double-firing within the same minute-check
}

// -----------------------------------------------------------------------
// Volumio lifecycle
// -----------------------------------------------------------------------

ControllerSmartPlaylists.prototype.onVolumioStart = function () {
  var self = this;
  var configFile = self.commandRouter.pluginManager.getConfigurationFile(self.context, 'config.json');
  self.config = new (require('v-conf'))();
  self.config.loadFile(configFile);
  return libQ.resolve();
};

ControllerSmartPlaylists.prototype.onStart = function () {
  var self = this;
  var defer = libQ.defer();

  // IMPORTANT SAFETY BEHAVIOR: never let an empty/default config silently
  // wipe out a rules file that already has real content on disk (this bit
  // a user during the textarea->per-line-fields migration, when the saved
  // config still had no rule_N values but the actual file on disk held
  // their real rules). On every start:
  //   - if the config has at least one non-empty rule line, write it to
  //     the file (config is the source of truth, as normal).
  //   - if the config is completely empty but the file already has real
  //     content, import the FILE into the config instead - the file wins,
  //     nothing gets clobbered.
  //   - if both are empty, nothing to do.
  self.migrateOldConfig();
  if (typeof self.commandRouter.addPluginRestEndpoint === 'function') {
    self.commandRouter.addPluginRestEndpoint(REST_ENDPOINT);
  }
  self.reconcileRulesFile()
    .then(function () {
      self.setupSchedule();
      defer.resolve();
    })
    .fail(function (err) {
      self.logger.error('[SmartPlaylists] Failed to reconcile rules file on start: ' + err);
      self.setupSchedule();
      defer.resolve();
    });

  return defer.promise;
};

ControllerSmartPlaylists.prototype.configHasRules = function () {
  for (var i = 1; i <= NUM_RULE_LINES; i++) {
    if (isRuleLine(this.config.get('rule_' + i))) return true;
  }
  return false;
};

// Settings from the old category (user_interface, up to 0.9.x): taken over
// once while the current config has no rules of its own.
ControllerSmartPlaylists.prototype.migrateOldConfig = function () {
  var self = this;
  if (self.configHasRules()) return;
  var old;
  try {
    old = fs.readJsonSync(OLD_CONFIG_FILE);
  } catch (e) {
    return;   // no old config (fresh install) or unreadable
  }
  var n = 0;
  Object.keys(old || {}).forEach(function (key) {
    if (!MIGRATED_KEYS.test(key) || !old[key] || old[key].value === undefined) return;
    self.config.set(key, old[key].value);
    n++;
  });
  if (n) self.logger.info('[SmartPlaylists] Settings taken over from ' + OLD_CONFIG_FILE + ' (' + n + ' values).');
};

ControllerSmartPlaylists.prototype.reconcileRulesFile = function () {
  var self = this;
  var defer = libQ.defer();

  // Only real rules count: the commented examples of a fresh config must not
  // overwrite a rules file that already exists (e.g. after a reinstall).
  if (self.configHasRules()) {
    // Config is the source of truth - write it out, as before.
    // IMPORTANT: pass closures, not bare "defer.resolve"/"defer.reject"
    // references - with kew, passing the deferred's methods detached
    // from their object can cause "Unable to resolve or reject the same
    // promise twice", which crashes the whole Volumio backend process.
    self.writeRulesFile()
      .then(function () {
        defer.resolve();
      })
      .fail(function (err) {
        defer.reject(err);
      });
    return defer.promise;
  }

  // Config is empty - check if the file already has real content before
  // doing anything. If it does, import it INTO the config rather than
  // overwriting the file with the empty config.
  var rulesPath = self.getRulesFilePath();
  fs.readFile(rulesPath, 'utf8')
    .then(function (fileContent) {
      var lines = fileContent.split('\n');
      var hasRealContent = lines.some(isRuleLine);
      if (!hasRealContent) {
        // Both empty, nothing to reconcile.
        defer.resolve();
        return;
      }
      self.logger.info('[SmartPlaylists] Config was empty but rules file has content - importing file into config instead of overwriting it.');
      for (var i = 1; i <= NUM_RULE_LINES; i++) {
        self.config.set('rule_' + i, lines[i - 1] !== undefined ? lines[i - 1] : '');
      }
      if (lines.length > NUM_RULE_LINES) {
        self.logger.error(
          '[SmartPlaylists] Rules file has ' + lines.length + ' lines but only the first ' +
          NUM_RULE_LINES + ' fit in the UI - extra lines were left untouched in the file but ' +
          'will NOT be editable/visible in the UI. Consider raising NUM_RULE_LINES.'
        );
      }
      defer.resolve();
    })
    .catch(function () {
      // File doesn't exist yet (fresh install) - nothing to import, nothing to write.
      defer.resolve();
    });

  return defer.promise;
};

ControllerSmartPlaylists.prototype.onStop = function () {
  var self = this;
  if (self.scheduleTimer) {
    clearInterval(self.scheduleTimer);
    self.scheduleTimer = null;
  }
  if (typeof self.commandRouter.removePluginRestEndpoint === 'function') {
    self.commandRouter.removePluginRestEndpoint(REST_ENDPOINT);
  }
  return libQ.resolve();
};

ControllerSmartPlaylists.prototype.onRestart = function () {
  var self = this;
  return libQ.resolve();
};

ControllerSmartPlaylists.prototype.getConfigurationFiles = function () {
  return ['config.json'];
};

// -----------------------------------------------------------------------
// UI Configuration
// -----------------------------------------------------------------------

ControllerSmartPlaylists.prototype.getUIConfig = function () {
  var defer = libQ.defer();
  var self = this;

  var lang_code = self.commandRouter.sharedVars.get('language_code');

  self.commandRouter
    .i18nJson(
      __dirname + '/i18n/strings_' + lang_code + '.json',
      __dirname + '/i18n/strings_en.json',
      __dirname + '/UIConfig.json'
    )
    .then(function (uiconf) {
      var scheduleSection = uiconf.sections[0];
      scheduleSection.content[0].value = self.config.get('schedule_enabled');
      scheduleSection.content[1].value = self.config.get('schedule_time');

      // Looked up by "id" rather than assumed array position: the rules
      // section's content array now also holds the three page-toggle
      // switches interspersed between rule blocks (see NUM_RULE_LINES
      // comment above), so "content[i - 1] === rule_i" no longer holds.
      var rulesSection = uiconf.sections[1];
      var rulesContentById = {};
      rulesSection.content.forEach(function (item) {
        rulesContentById[item.id] = item;
      });
      rulesContentById['rules_page1_enabled'].value = self.config.get('rules_page1_enabled') !== false;
      rulesContentById['rules_page2_enabled'].value = !!self.config.get('rules_page2_enabled');
      rulesContentById['rules_page3_enabled'].value = !!self.config.get('rules_page3_enabled');
      for (var i = 1; i <= NUM_RULE_LINES; i++) {
        rulesContentById['rule_' + i].value = self.config.get('rule_' + i) || '';
      }

      defer.resolve(uiconf);
    })
    .fail(function (error) {
      self.logger.error('[SmartPlaylists] Failed to parse UI Configuration page: ' + error);
      defer.reject(new Error());
    });

  return defer.promise;
};

// -----------------------------------------------------------------------
// Path helpers
// -----------------------------------------------------------------------

ControllerSmartPlaylists.prototype.getRulesFilePath = function () {
  return path.join(PLUGIN_DATA_DIR, 'smart_playlists.txt');
};

ControllerSmartPlaylists.prototype.getCoreScriptPath = function () {
  return path.join(__dirname, 'smart-playlists-core.sh');
};

// -----------------------------------------------------------------------
// Settings save handlers (bound to UIConfig.json "onSave"/"onClick")
// -----------------------------------------------------------------------

// Defensive string coercion: guards against a value being the JS
// primitives undefined/null (normal case, "||" already handles these),
// but ALSO against the literal 4-/-character strings "undefined" or
// "null" - which some frontend serialization paths can produce for an
// untouched/empty form field instead of a genuine empty string. Both
// cases are treated as "no value".
function safeString(v) {
  if (v === undefined || v === null) return '';
  var s = String(v);
  if (s === 'undefined' || s === 'null') return '';
  return s;
}

// Some Volumio builds (confirmed: Volumio 2's CoreCommandRouter) never load
// a plugin's own i18n/strings_*.json - only the core's own strings file -
// so getI18nString('SMART_PLAYLISTS.xxx') throws (reading a property off
// the undefined 'SMART_PLAYLISTS' namespace) instead of returning ''.
// Falls back to the given (English) default in that case.
ControllerSmartPlaylists.prototype.i18n = function (key, fallback) {
  var self = this;
  try {
    var value = self.commandRouter.getI18nString('SMART_PLAYLISTS.' + key);
    if (value) {
      return value;
    }
  } catch (err) {
    // fall through to fallback
  }
  return fallback;
};

ControllerSmartPlaylists.prototype.saveSettings = function (data) {
  var self = this;
  var defer = libQ.defer();

  try {
    self.config.set('schedule_enabled', !!data['schedule_enabled']);
    self.config.set('schedule_time', safeString(data['schedule_time']) || '03:00');

    self.setupSchedule();

    self.commandRouter.pushToastMessage(
      'success',
      self.i18n('PLUGIN_NAME', 'Smart Playlists'),
      self.i18n('TOAST_SETTINGS_SAVED', 'Settings saved')
    );
    defer.resolve({});
  } catch (err) {
    self.logger.error('[SmartPlaylists] saveSettings failed: ' + (err && err.stack ? err.stack : err));
    defer.reject(new Error());
  }

  return defer.promise;
};

ControllerSmartPlaylists.prototype.saveRules = function (data) {
  var self = this;
  var defer = libQ.defer();

  try {
    self.config.set('rules_page1_enabled', !!data['rules_page1_enabled']);
    self.config.set('rules_page2_enabled', !!data['rules_page2_enabled']);
    self.config.set('rules_page3_enabled', !!data['rules_page3_enabled']);
    for (var i = 1; i <= NUM_RULE_LINES; i++) {
      var key = 'rule_' + i;
      self.config.set(key, safeString(data[key]));
    }
  } catch (err) {
    self.logger.error('[SmartPlaylists] saveRules failed while setting config: ' + (err && err.stack ? err.stack : err));
    defer.reject(new Error());
    return defer.promise;
  }

  self
    .writeRulesFile()
    .then(function () {
      self.commandRouter.pushToastMessage(
        'success',
        self.i18n('PLUGIN_NAME', 'Smart Playlists'),
        self.i18n('TOAST_RULES_SAVED', 'Rules saved')
      );
      defer.resolve({});
    })
    .fail(function (err) {
      self.logger.error('[SmartPlaylists] Failed to write rules file: ' + (err && err.stack ? err.stack : err));
      defer.reject(new Error());
    });

  return defer.promise;
};

ControllerSmartPlaylists.prototype.writeRulesFile = function () {
  var self = this;
  var defer = libQ.defer();

  var rulesPath = self.getRulesFilePath();
  var rulesDir = path.dirname(rulesPath);

  var lines = [];
  for (var i = 1; i <= NUM_RULE_LINES; i++) {
    lines.push(safeString(self.config.get('rule_' + i)));
  }
  var content = lines.join('\n') + '\n';

  // the previous rules stay as <file>.bak whenever real rules get replaced,
  // so a wrong overwrite can always be undone
  fs.ensureDir(rulesDir)
    .then(function () {
      return fs.readFile(rulesPath, 'utf8').catch(function () { return ''; });
    })
    .then(function (old) {
      if (old !== content && old.split('\n').some(isRuleLine)) return fs.writeFile(rulesPath + '.bak', old, 'utf8');
    })
    .then(function () {
      return fs.writeFile(rulesPath, content, 'utf8');
    })
    .then(function () {
      defer.resolve();
    })
    .catch(function (err) {
      defer.reject(err);
    });

  return defer.promise;
};

// -----------------------------------------------------------------------
// Running the core script
// -----------------------------------------------------------------------

ControllerSmartPlaylists.prototype.runNow = function () {
  var self = this;
  var defer = libQ.defer();

  if (self.running) {
    self.commandRouter.pushToastMessage(
      'info',
      self.i18n('PLUGIN_NAME', 'Smart Playlists'),
      self.i18n('TOAST_RUN_BUSY', 'Playlists are already being built - please wait until this run has finished.')
    );
    defer.resolve({});
    return defer.promise;
  }

  self.commandRouter.pushToastMessage(
    'info',
    self.i18n('PLUGIN_NAME', 'Smart Playlists'),
    self.i18n('TOAST_RUN_STARTED', 'Building playlists - this can take a while on first run or after adding many files...')
  );

  self
    .reconcileRulesFile()
    .then(function () {
      return self.executeScript();
    })
    .then(function () {
      self.commandRouter.pushToastMessage(
        'success',
        self.i18n('PLUGIN_NAME', 'Smart Playlists'),
        self.i18n('TOAST_RUN_SUCCESS', 'Playlists updated successfully')
      );
      defer.resolve({});
    })
    .fail(function (err) {
      self.logger.error('[SmartPlaylists] Run failed: ' + (err && err.stack ? err.stack : err));
      self.commandRouter.pushToastMessage(
        'error',
        self.i18n('PLUGIN_NAME', 'Smart Playlists'),
        self.i18n('TOAST_RUN_ERROR', 'Playlist generation failed - check the log')
      );
      defer.reject(new Error());
    });

  return defer.promise;
};

ControllerSmartPlaylists.prototype.executeScript = function () {
  var self = this;
  var defer = libQ.defer();

  var scriptPath = self.getCoreScriptPath();

  // No SMART_PLAYLISTS_MUSIC_DIR/MPD_ROOT/MPD_SOURCE_LABEL anymore - the
  // core script now scans all of Volumio's standard sources (INTERNAL,
  // USB, NAS) by default and figures out the right uri per file itself.
  var env = Object.assign({}, process.env, {
    SMART_PLAYLISTS_WORK_DIR: PLUGIN_DATA_DIR
  });

  // No timeout set deliberately - a first-time full library scan can take
  // a long time (~20 min for ~24k tracks in testing). Subsequent runs are
  // fast thanks to the script's own incremental cache.
  if (self.running) {
    defer.reject(new Error('a run is already in progress'));
    return defer.promise;
  }
  self.running = true;
  execFile('/bin/bash', [scriptPath], { env: env, maxBuffer: 1024 * 1024 * 10 }, function (error, stdout, stderr) {
    self.running = false;
    self.lastRun = { at: Date.now(), ok: !error };
    if (self.rerunWanted) {
      self.rerunWanted = false;
      setTimeout(function () {
        self.executeScript().fail(function (err) {
          self.logger.error('[SmartPlaylists] Follow-up run failed: ' + err);
        });
      }, 0);
    }
    if (error) {
      self.logger.error('[SmartPlaylists] script exited with error: ' + error);
      if (stderr) {
        self.logger.error('[SmartPlaylists] stderr (last lines): ' + String(stderr).trim().split('\n').slice(-10).join('\n'));
      }
      defer.reject(error);
    } else {
      defer.resolve();
    }
  });

  return defer.promise;
};

// -----------------------------------------------------------------------
// REST API for other frontends (Xplorio's playlist editor)
// -----------------------------------------------------------------------
//
// data.action:
//   'list'     -> {ok, api, max, running, lastRun, rules: [{slot, line, name, playlist, created}]}
//   'save'     {slot (0 or missing = first free line), line, run (default true)}
//              -> {ok, slot, playlist}; the line must carry a name ("Name::...")
//   'delete'   {slot} -> {ok}; also removes the generated playlist
//   'run'      -> {ok, running}; during a run, one more run follows it
//   'status'   -> {ok, running, lastRun}
//   'preview'  {line} -> {ok, count, tracks: [{title, artist, album}] (first 10)}
// Errors: {ok: false, error: 'bad_action' | 'bad_line' | 'no_name' | 'name_taken'
//          | 'full' | 'bad_slot' | 'busy' | 'failed'}
// Always resolves, so the caller gets the answer instead of an HTTP error.

// Same as sanitize_name in smart-playlists-core.sh: the file name, and so
// the name Volumio shows, of the playlist a rule line creates.
function sanitizeName(name) {
  var out = String(name)
    .replace(/[\/:"\\?*]/g, '_')
    .replace(/[\x00-\x1f]/g, '')
    .replace(/^ +| +$/g, '')
    .replace(/ {2,}/g, ' ');
  if (out === '' || out === '.' || out === '..') return 'unnamed';
  if (out.charAt(0) === '.') return '_' + out;
  return out;
}

// The playlist name a rule line results in (as the core script derives it).
function playlistOf(line) {
  line = String(line).replace(/\r$/, '');
  var i = line.indexOf('::');
  if (i >= 0) return sanitizeName(line.slice(0, i).trim());
  return sanitizeName(line.replace(/;/g, ', '));
}

// Own name of a rule line ("Name::..."), '' without one.
function ruleName(line) {
  var i = String(line).indexOf('::');
  return i >= 0 ? String(line).slice(0, i).trim() : '';
}

// Checks a rule line coming in over REST; returns an error code or ''.
function checkLine(line) {
  if (typeof line !== 'string') return 'bad_line';
  if (/[\r\n]/.test(line) || line.length > MAX_RULE_LENGTH || !isRuleLine(line)) return 'bad_line';
  if (!ruleName(line)) return 'no_name';
  var rest = line.slice(line.indexOf('::') + 2).trim();
  if (!rest || rest.charAt(0) === '|') return 'bad_line';   // no artist list and no "*"
  return '';
}

ControllerSmartPlaylists.prototype.restApi = function (data) {
  var self = this;
  data = data || {};
  var answer;
  try {
    switch (data.action || 'list') {
      case 'list': answer = self.apiList(); break;
      case 'status': answer = libQ.resolve(self.apiStatus()); break;
      case 'save': answer = self.apiSave(data); break;
      case 'delete': answer = self.apiDelete(data); break;
      case 'run': answer = libQ.resolve(self.apiRun()); break;
      case 'preview': answer = self.apiPreview(data); break;
      default: answer = libQ.resolve({ ok: false, error: 'bad_action' });
    }
  } catch (err) {
    self.logger.error('[SmartPlaylists] REST ' + data.action + ' failed: ' + (err && err.stack ? err.stack : err));
    answer = libQ.resolve({ ok: false, error: 'failed' });
  }
  return answer.fail(function (err) {
    self.logger.error('[SmartPlaylists] REST ' + data.action + ' failed: ' + (err && err.stack ? err.stack : err));
    return { ok: false, error: 'failed' };
  });
};

ControllerSmartPlaylists.prototype.apiStatus = function () {
  return { ok: true, api: API_VERSION, running: !!this.running, lastRun: this.lastRun };
};

// Names of the playlists the core script created (its manifest).
ControllerSmartPlaylists.prototype.readManifest = function () {
  var defer = libQ.defer();
  fs.readFile(path.join(PLUGIN_DATA_DIR, MANIFEST_NAME), 'utf8')
    .then(function (text) {
      defer.resolve(text.split('\n').filter(function (n) { return n !== ''; }));
    })
    .catch(function () { defer.resolve([]); });
  return defer.promise;
};

ControllerSmartPlaylists.prototype.apiList = function () {
  var self = this;
  return self.readManifest().then(function (made) {
    var rules = [];
    for (var i = 1; i <= NUM_RULE_LINES; i++) {
      var line = safeString(self.config.get('rule_' + i));
      if (!isRuleLine(line)) continue;
      var pl = playlistOf(line.trim());
      rules.push({ slot: i, line: line.trim(), name: ruleName(line), playlist: pl, created: made.indexOf(pl) >= 0 });
    }
    var st = self.apiStatus();
    st.max = NUM_RULE_LINES;
    st.rules = rules;
    return st;
  });
};

// Writes the rule lines to the config and the rules file, and shows the
// page of every used line on the settings page.
ControllerSmartPlaylists.prototype.storeRule = function (slot, line) {
  var self = this;
  self.config.set('rule_' + slot, line);
  if (line) self.config.set('rules_page' + Math.ceil(slot / 30) + '_enabled', true);
  return self.writeRulesFile();
};

ControllerSmartPlaylists.prototype.apiSave = function (data) {
  var self = this;
  var line = typeof data.line === 'string' ? data.line.trim() : data.line;
  var bad = checkLine(line);
  if (bad) return libQ.resolve({ ok: false, error: bad });

  var slot = parseInt(data.slot, 10) || 0;
  if (slot < 0 || slot > NUM_RULE_LINES) return libQ.resolve({ ok: false, error: 'bad_slot' });

  var pl = playlistOf(line);
  var free = 0;
  for (var i = 1; i <= NUM_RULE_LINES; i++) {
    var other = safeString(self.config.get('rule_' + i));
    if (!isRuleLine(other)) {
      if (!free && !other.trim()) free = i;   // a comment line is never overwritten
      continue;
    }
    if (i !== slot && playlistOf(other.trim()) === pl) return libQ.resolve({ ok: false, error: 'name_taken' });
  }
  if (!slot) slot = free;
  if (!slot) return libQ.resolve({ ok: false, error: 'full' });

  return self.storeRule(slot, line).then(function () {
    if (data.run !== false) self.apiRun();
    return { ok: true, slot: slot, playlist: pl };
  });
};

ControllerSmartPlaylists.prototype.apiDelete = function (data) {
  var self = this;
  var slot = parseInt(data.slot, 10) || 0;
  if (slot < 1 || slot > NUM_RULE_LINES) return libQ.resolve({ ok: false, error: 'bad_slot' });
  var line = safeString(self.config.get('rule_' + slot));
  if (!isRuleLine(line)) return libQ.resolve({ ok: false, error: 'bad_slot' });
  var pl = playlistOf(line.trim());

  return self.storeRule(slot, '')
    .then(function () { return self.readManifest(); })
    .then(function (made) {
      // Removed right away: the core script keeps all playlists when the
      // last rule is gone, and nobody should wait for a run to see it go.
      // Only a playlist the plugin created itself is touched.
      if (made.indexOf(pl) < 0) return;
      var still = false;
      for (var i = 1; i <= NUM_RULE_LINES; i++) {
        var other = safeString(self.config.get('rule_' + i));
        if (isRuleLine(other) && playlistOf(other.trim()) === pl) still = true;
      }
      if (still) return;
      var rest = made.filter(function (n) { return n !== pl; });
      return fs.remove(path.join(PLAYLIST_DIR, pl))
        .then(function () {
          return fs.writeFile(path.join(PLUGIN_DATA_DIR, MANIFEST_NAME), rest.length ? rest.join('\n') + '\n' : '', 'utf8');
        });
    })
    .then(function () {
      if (self.configHasRules()) self.apiRun();
      return { ok: true };
    });
};

ControllerSmartPlaylists.prototype.apiRun = function () {
  var self = this;
  if (self.running) {
    self.rerunWanted = true;
  } else {
    self.reconcileRulesFile()
      .then(function () { return self.executeScript(); })
      .fail(function (err) {
        self.logger.error('[SmartPlaylists] Run over REST failed: ' + err);
      });
  }
  return { ok: true, running: true };
};

// Runs the core script on this one line alone, in a folder of its own, so
// neither the real playlists nor the manifest are touched.
ControllerSmartPlaylists.prototype.apiPreview = function (data) {
  var self = this;
  var line = typeof data.line === 'string' ? data.line.trim() : data.line;
  var bad = checkLine(line);
  if (bad === 'no_name') {
    line = 'Preview::' + line;
    bad = checkLine(line);
  }
  if (bad) return libQ.resolve({ ok: false, error: bad });
  if (self.previewing) return libQ.resolve({ ok: false, error: 'busy' });
  self.previewing = true;

  var defer = libQ.defer();
  var dir = '';
  var done = function (answer) {
    self.previewing = false;
    if (dir) fs.remove(dir).catch(function () {});
    defer.resolve(answer);
  };

  fs.mkdtemp(path.join(os.tmpdir(), 'smart-playlists-preview-'))
    .then(function (d) {
      dir = d;
      return fs.writeFile(path.join(dir, 'smart_playlists.txt'), line + '\n', 'utf8');
    })
    .then(function () {
      var env = Object.assign({}, process.env, {
        SMART_PLAYLISTS_WORK_DIR: dir,
        SMART_PLAYLISTS_OUT_DIR: path.join(dir, 'out')
      });
      execFile('/bin/bash', [self.getCoreScriptPath()], { env: env, timeout: PREVIEW_TIMEOUT_MS, maxBuffer: 1024 * 1024 * 10 }, function (error) {
        if (error) {
          self.logger.error('[SmartPlaylists] Preview failed: ' + error);
          return done({ ok: false, error: 'failed' });
        }
        fs.readJson(path.join(dir, 'out', playlistOf(line)))
          .then(function (list) {
            list = Array.isArray(list) ? list : [];
            done({
              ok: true,
              count: list.length,
              tracks: list.slice(0, 10).map(function (t) {
                return { title: t.title || '', artist: t.artist || '', album: t.album || '' };
              })
            });
          })
          .catch(function () { done({ ok: true, count: 0, tracks: [] }); });   // no match: no file
      });
    })
    .catch(function (err) {
      self.logger.error('[SmartPlaylists] Preview failed: ' + err);
      done({ ok: false, error: 'failed' });
    });

  return defer.promise;
};

ControllerSmartPlaylists.helpers = {
  sanitizeName: sanitizeName,
  playlistOf: playlistOf,
  ruleName: ruleName,
  checkLine: checkLine
};

// -----------------------------------------------------------------------
// Scheduling
// -----------------------------------------------------------------------
//
// Deliberately dependency-free (no cron/node-schedule package): checks
// once a minute whether the current HH:MM matches the configured
// schedule_time and whether we haven't already run today, to avoid
// pulling in a compiled dependency for something this simple. Note this
// means the schedule is only as reliable as the plugin process staying
// up - if you need guaranteed execution even across Volumio restarts at
// exactly the scheduled time, a systemd timer calling the core script
// directly (see README) is more robust.

ControllerSmartPlaylists.prototype.setupSchedule = function () {
  var self = this;

  if (self.scheduleTimer) {
    clearInterval(self.scheduleTimer);
    self.scheduleTimer = null;
  }

  if (!self.config.get('schedule_enabled')) {
    return;
  }

  self.scheduleTimer = setInterval(function () {
    self.checkSchedule();
  }, 60 * 1000);
};

ControllerSmartPlaylists.prototype.checkSchedule = function () {
  var self = this;

  var scheduleTime = (self.config.get('schedule_time') || '03:00').trim();
  var now = new Date();
  var hh = String(now.getHours()).padStart(2, '0');
  var mm = String(now.getMinutes()).padStart(2, '0');
  var currentTime = hh + ':' + mm;
  var today = now.toISOString().slice(0, 10);

  if (currentTime === scheduleTime && self.lastRunDate !== today && !self.running) {
    self.lastRunDate = today;
    self.executeScript().fail(function (err) {
      self.logger.error('[SmartPlaylists] Scheduled run failed: ' + err);
    });
  }
};
