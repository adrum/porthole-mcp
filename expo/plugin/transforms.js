'use strict';

// Pure text transforms behind the config plugin. Each one is idempotent:
// running it on its own output changes nothing.

const SWIFT_BEGIN = '// @generated begin porthole-mcp';
const SWIFT_END = '// @generated end porthole-mcp';

class PluginError extends Error {
  constructor(message) {
    super(`porthole-mcp: ${message}`);
    this.name = 'PluginError';
  }
}

function escapeRegExp(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

/** Remove a generated block (and the newline after it), if present. */
function stripBlock(text, begin, end) {
  const re = new RegExp(`[ \\t]*${escapeRegExp(begin)}[\\s\\S]*?${escapeRegExp(end)}[^\\n]*\\n?`, 'g');
  return text.replace(re, '');
}

/**
 * Start the harness at the top of didFinishLaunchingWithOptions in a Swift
 * AppDelegate, inside #if DEBUG.
 * @param {string} source AppDelegate.swift contents
 * @param {{hub?: string}} opts hub: the hub to dial, unix:/path/to/hub.sock
 */
function addStart(source, { hub } = {}) {
  if (typeof source !== 'string' || !source.trim()) {
    throw new PluginError('the AppDelegate is empty');
  }
  if (/@implementation\s+AppDelegate/.test(source)) {
    throw new PluginError('only a Swift AppDelegate is supported (Expo SDK 51 and later); this one is Objective-C');
  }
  if (hub !== undefined && !(typeof hub === 'string' && /^unix:\/[^"\\\n]+$/.test(hub))) {
    throw new PluginError(`hub must look like "unix:/path/to/hub.sock", got ${JSON.stringify(hub)}`);
  }
  let text = stripBlock(stripBlock(source, SWIFT_BEGIN, SWIFT_END), SWIFT_BEGIN, SWIFT_END);

  // The import goes after the last top-level import line.
  const imports = [...text.matchAll(/^(?:@?[\w ]*\s)?import\s+[\w.]+[ \t]*$/gm)];
  if (imports.length === 0) {
    throw new PluginError("couldn't find any import lines in the AppDelegate");
  }
  const lastImport = imports[imports.length - 1];
  const importAt = lastImport.index + lastImport[0].length;
  const importBlock = `\n${SWIFT_BEGIN}\n#if DEBUG\nimport Porthole\n#endif\n${SWIFT_END}`;
  text = text.slice(0, importAt) + importBlock + text.slice(importAt);

  const fn = /func\s+application\s*\(\s*_\s+application\s*:\s*UIApplication\s*,\s*didFinishLaunchingWithOptions[\s\S]*?\)\s*->\s*Bool\s*\{/m.exec(text);
  if (!fn) {
    throw new PluginError(
      "couldn't find application(_:didFinishLaunchingWithOptions:) in the AppDelegate; add `Porthole.start()` there yourself inside #if DEBUG",
    );
  }
  const bodyAt = fn.index + fn[0].length;
  const lineStart = text.lastIndexOf('\n', fn.index) + 1;
  const baseIndent = /^[ \t]*/.exec(text.slice(lineStart))[0];
  const indent = `${baseIndent}  `;
  const call = hub ? `Porthole.start(Porthole.Options(hub: "${hub}"))` : 'Porthole.start()';
  const startBlock =
    `\n${indent}${SWIFT_BEGIN}\n` +
    `#if DEBUG\n${indent}${call}\n#endif\n` +
    `${indent}${SWIFT_END}`;
  return text.slice(0, bodyAt) + startBlock + text.slice(bodyAt);
}

/**
 * Add a local Swift package (the harness sources) to the app target of a
 * parsed Xcode project (the `xcode` npm package's object).
 * @param {object} project xcode project
 * @param {{relativePath: string, targetName?: string}} opts relativePath from the .xcodeproj's directory
 */
function addSwiftPackage(project, { relativePath, targetName }) {
  const objects = project.hash.project.objects;
  const section = (name) => (objects[name] = objects[name] || {});
  const uuid = () => project.generateUuid();
  const projectId = project.getFirstProject().uuid;
  const projectObj = objects.PBXProject[projectId];

  const nativeTargets = objects.PBXNativeTarget || {};
  const targetId = Object.keys(nativeTargets).find((k) => {
    if (k.endsWith('_comment')) return false;
    const t = nativeTargets[k];
    const name = String(t.name).replace(/"/g, '');
    return targetName ? name === targetName : String(t.productType).includes('application');
  });
  if (!targetId) {
    throw new PluginError(targetName ? `no native target named ${targetName}` : 'no application target in the Xcode project');
  }
  const target = nativeTargets[targetId];

  const refs = section('XCLocalSwiftPackageReference');
  let refId = Object.keys(refs).find((k) => !k.endsWith('_comment') && String(refs[k].relativePath).replace(/"/g, '') === relativePath);
  if (!refId) {
    refId = uuid();
    refs[refId] = { isa: 'XCLocalSwiftPackageReference', relativePath: JSON.stringify(relativePath) };
    refs[`${refId}_comment`] = `XCLocalSwiftPackageReference "${relativePath}"`;
    projectObj.packageReferences = projectObj.packageReferences || [];
    projectObj.packageReferences.push({ value: refId, comment: `XCLocalSwiftPackageReference "${relativePath}"` });
  }

  const deps = section('XCSwiftPackageProductDependency');
  let depId = Object.keys(deps).find((k) => !k.endsWith('_comment') && deps[k].productName === 'Porthole' && deps[k].package === refId);
  if (!depId) {
    depId = uuid();
    deps[depId] = { isa: 'XCSwiftPackageProductDependency', package: refId, package_comment: `XCLocalSwiftPackageReference "${relativePath}"`, productName: 'Porthole' };
    deps[`${depId}_comment`] = 'Porthole';
    target.packageProductDependencies = target.packageProductDependencies || [];
    target.packageProductDependencies.push({ value: depId, comment: 'Porthole' });

    const files = section('PBXBuildFile');
    const fileId = uuid();
    files[fileId] = { isa: 'PBXBuildFile', productRef: depId, productRef_comment: 'Porthole' };
    files[`${fileId}_comment`] = 'Porthole in Frameworks';
    const phases = objects.PBXFrameworksBuildPhase || {};
    const phaseRef = (target.buildPhases || []).find((p) => phases[p.value]);
    if (!phaseRef) {
      throw new PluginError(`target ${target.name} has no Frameworks build phase`);
    }
    phases[phaseRef.value].files = phases[phaseRef.value].files || [];
    phases[phaseRef.value].files.push({ value: fileId, comment: 'Porthole in Frameworks' });
  }
  return project;
}

module.exports = { addStart, addSwiftPackage, PluginError, SWIFT_BEGIN, SWIFT_END };
