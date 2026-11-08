'use strict';

// Runs the plugin's transforms against real `expo prebuild` output
// (Expo SDK 58, React Native 0.88) in test/fixtures/sdk58.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const xcode = require('xcode');
const { addStart, addSwiftPackage } = require('../plugin/transforms');

const fixture = (name) => fs.readFileSync(path.join(__dirname, 'fixtures', 'sdk58', name), 'utf8');

test('starts the harness first thing in didFinishLaunchingWithOptions', () => {
  const out = addStart(fixture('AppDelegate.swift'));
  assert.match(out, /import ReactAppDependencyProvider\n\/\/ @generated begin porthole-mcp\n#if DEBUG\nimport Porthole\n#endif\n\/\/ @generated end porthole-mcp\n/);
  assert.match(
    out,
    /didFinishLaunchingWithOptions launchOptions: \[UIApplication\.LaunchOptionsKey: Any\]\? = nil\n  \) -> Bool \{\n    \/\/ @generated begin porthole-mcp\n#if DEBUG\n    Porthole\.start\(\)\n#endif\n    \/\/ @generated end porthole-mcp\n    let delegate = ReactNativeDelegate\(\)/,
  );
});

test('the AppDelegate change is idempotent and takes a hub', () => {
  const once = addStart(fixture('AppDelegate.swift'));
  assert.equal(addStart(once), once);
  const withHub = addStart(once, { hub: 'unix:/tmp/custom/hub.sock' });
  assert.equal((withHub.match(/Porthole\.start/g) || []).length, 1);
  assert.match(withHub, /Porthole\.start\(Porthole\.Options\(hub: "unix:\/tmp\/custom\/hub\.sock"\)\)/);
  assert.equal((withHub.match(/import Porthole/g) || []).length, 1);
  assert.equal(addStart(withHub), addStart(once), 'dropping the hub restores the default');
});

test('bad AppDelegates and options are clear errors', () => {
  assert.throws(() => addStart('#import "AppDelegate.h"\n@implementation AppDelegate\n@end\n'), /Objective-C/);
  assert.throws(() => addStart('import UIKit\nclass AppDelegate {}\n'), /didFinishLaunchingWithOptions/);
  assert.throws(() => addStart(fixture('AppDelegate.swift'), { hub: 8123 }), /hub must look like/);
  assert.throws(() => addStart(fixture('AppDelegate.swift'), { hub: 'ws://10.0.0.2:9000' }), /hub must look like/);
  assert.throws(() => addStart(fixture('AppDelegate.swift'), { hub: 'unix:/tmp/a"b' }), /hub must look like/);
});

test('adds a local Swift package product to the app target', () => {
  const project = xcode.project(path.join(__dirname, 'fixtures', 'sdk58', 'project.pbxproj'));
  project.parseSync();
  addSwiftPackage(project, { relativePath: '../node_modules/porthole-mcp/native', targetName: 'expofixture' });
  addSwiftPackage(project, { relativePath: '../node_modules/porthole-mcp/native', targetName: 'expofixture' });
  const text = project.writeSync();
  assert.equal((text.match(/isa = XCLocalSwiftPackageReference;/g) || []).length, 1);
  assert.equal((text.match(/isa = XCSwiftPackageProductDependency;/g) || []).length, 1);
  assert.match(text, /relativePath = "\.\.\/node_modules\/porthole-mcp\/native";/);
  assert.match(text, /productName = Porthole;/);
  assert.match(text, /packageReferences = \(\s*[0-9A-F]{24} \/\* XCLocalSwiftPackageReference/);
  assert.match(text, /packageProductDependencies = \(\s*[0-9A-F]{24} \/\* Porthole \*\//);
  assert.match(text, /[0-9A-F]{24} \/\* Porthole in Frameworks \*\/ = \{isa = PBXBuildFile; productRef = [0-9A-F]{24} \/\* Porthole \*\/; \};/);
  // The result parses back.
  const again = xcode.project(path.join(__dirname, 'fixtures', 'sdk58', 'project.pbxproj'));
  again.hash = require('xcode/lib/parser/pbxproj').parse(text);
  assert.ok(again.hash.project.objects.XCLocalSwiftPackageReference);
  assert.throws(() => addSwiftPackage(project, { relativePath: 'x', targetName: 'nope' }), /no native target named nope/);
});
