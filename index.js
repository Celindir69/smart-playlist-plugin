'use strict';

var libQ = require('kew');
var fs = require('fs-extra');
var path = require('path');
var exec = require('child_process').exec;

// Must match the number of "rule_N" fields generated in config.json and
// UIConfig.json (single-line inputs, since Volumio's UI schema has no
// confirmed multi-line "textarea" element).
var NUM_RULE_LINES = 30;

// Where the rules file, cache, manifest, and debug log live. Deliberately
// NOT inside the music folder (avoids accidental edits/deletion via
// Samba/file manager) and NOT inside the plugin's own install folder
// under /data/plugins/... (which gets wiped on plugin uninstall - and
// re-running "volumio plugin install" after "volumio plugin uninstall"
// for every update, rather than "volumio plugin refresh", is a common
// dev workflow). This path is untouched by either of those, so it
// survives both.
var PLUGIN_DATA_DIR = '/data/smart_playlists_data';

module.exports = ControllerSmartPlaylists;

function ControllerSmartPlaylists(context) {
  var self = this;

  self.context = context;
  self.commandRouter = self.context.coreCommand;
  self.logger = self.context.logger;
  self.configManager = self.context.configManager;

  self.scheduleTimer = null;
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

ControllerSmartPlaylists.prototype.reconcileRulesFile = function () {
  var self = this;
  var defer = libQ.defer();

  var configHasContent = false;
  for (var i = 1; i <= NUM_RULE_LINES; i++) {
    if ((self.config.get('rule_' + i) || '').trim() !== '') {
      configHasContent = true;
      break;
    }
  }

  if (configHasContent) {
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
      var hasRealContent = lines.some(function (l) {
        return l.trim() !== '';
      });
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

      var rulesSection = uiconf.sections[1];
      for (var i = 1; i <= NUM_RULE_LINES; i++) {
        rulesSection.content[i - 1].value = self.config.get('rule_' + i) || '';
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

ControllerSmartPlaylists.prototype.saveSettings = function (data) {
  var self = this;
  var defer = libQ.defer();

  try {
    self.config.set('schedule_enabled', !!data['schedule_enabled']);
    self.config.set('schedule_time', safeString(data['schedule_time']) || '03:00');

    self.setupSchedule();

    self.commandRouter.pushToastMessage(
      'success',
      self.commandRouter.getI18nString('SMART_PLAYLISTS.PLUGIN_NAME'),
      self.commandRouter.getI18nString('SMART_PLAYLISTS.TOAST_SETTINGS_SAVED')
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
        self.commandRouter.getI18nString('SMART_PLAYLISTS.PLUGIN_NAME'),
        self.commandRouter.getI18nString('SMART_PLAYLISTS.TOAST_RULES_SAVED')
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

  fs.ensureDir(rulesDir)
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

  self.commandRouter.pushToastMessage(
    'info',
    self.commandRouter.getI18nString('SMART_PLAYLISTS.PLUGIN_NAME'),
    self.commandRouter.getI18nString('SMART_PLAYLISTS.TOAST_RUN_STARTED')
  );

  self
    .reconcileRulesFile()
    .then(function () {
      return self.executeScript();
    })
    .then(function () {
      self.commandRouter.pushToastMessage(
        'success',
        self.commandRouter.getI18nString('SMART_PLAYLISTS.PLUGIN_NAME'),
        self.commandRouter.getI18nString('SMART_PLAYLISTS.TOAST_RUN_SUCCESS')
      );
      defer.resolve({});
    })
    .fail(function (err) {
      self.logger.error('[SmartPlaylists] Run failed: ' + (err && err.stack ? err.stack : err));
      self.commandRouter.pushToastMessage(
        'error',
        self.commandRouter.getI18nString('SMART_PLAYLISTS.PLUGIN_NAME'),
        self.commandRouter.getI18nString('SMART_PLAYLISTS.TOAST_RUN_ERROR')
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
  exec('/bin/bash "' + scriptPath + '"', { env: env, maxBuffer: 1024 * 1024 * 10 }, function (error, stdout, stderr) {
    if (error) {
      self.logger.error('[SmartPlaylists] script exited with error: ' + error);
      if (stderr) {
        self.logger.error('[SmartPlaylists] stderr: ' + stderr);
      }
      defer.reject(error);
    } else {
      self.logger.info('[SmartPlaylists] run completed successfully');
      defer.resolve();
    }
  });

  return defer.promise;
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

  if (currentTime === scheduleTime && self.lastRunDate !== today) {
    self.lastRunDate = today;
    self.logger.info('[SmartPlaylists] Scheduled run starting');
    self.executeScript().fail(function (err) {
      self.logger.error('[SmartPlaylists] Scheduled run failed: ' + err);
    });
  }
};
