'use strict';

const path = require('path');
const { addStart, addSwiftPackage, PluginError } = require('./transforms');

/**
 * The app's own config-plugins. Resolve from the app (the working directory
 * of `expo prebuild`) first: when this package is linked (file: or a
 * workspace), Node resolves our requires from its real path, where no
 * `expo` is installed.
 */
function configPlugins() {
  const paths = [process.cwd(), __dirname];
  for (const id of ['expo/config-plugins', '@expo/config-plugins']) {
    try {
      return require(require.resolve(id, { paths }));
    } catch {
      // try the next one
    }
  }
  throw new PluginError("can't find expo/config-plugins; run expo prebuild from the app's directory with expo installed");
}

/** Directory holding the harness Swift package inside this package. */
function nativeDir() {
  return path.resolve(__dirname, '..', 'native');
}

/**
 * Expo config plugin: adds the Porthole harness to the iOS app target as a
 * local Swift package and starts it at launch. The harness compiles only
 * under #if DEBUG, so Release builds get empty stubs.
 *
 * Options:
 *   hub: the hub to dial, "unix:/path/to/hub.sock" (default: the standard
 *        porthole-mcp hub socket)
 */
function withPorthole(config, options = {}) {
  const { withAppDelegate, withXcodeProject } = configPlugins();

  config = withAppDelegate(config, (cfg) => {
    if (cfg.modResults.language !== 'swift') {
      throw new PluginError(`only a Swift AppDelegate is supported; found ${cfg.modResults.language}`);
    }
    cfg.modResults.contents = addStart(cfg.modResults.contents, { hub: options.hub });
    return cfg;
  });

  config = withXcodeProject(config, (cfg) => {
    // Local package paths are relative to the directory holding the .xcodeproj (ios/).
    const relativePath = path.relative(cfg.modRequest.platformProjectRoot, nativeDir());
    addSwiftPackage(cfg.modResults, { relativePath, targetName: cfg.modRequest.projectName });
    return cfg;
  });
  return config;
}

module.exports = withPorthole;
module.exports.withPorthole = withPorthole;
