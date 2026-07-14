'use strict';

// Resolves the next beta or stable semver for this package, based on
// package.json's current version plus existing git tags. Fully generic —
// copy as-is into a new NeoLabs product's scripts/ directory. See
// ../../docs-template/docs/release-process.md for the versioning scheme.

const fs = require('fs');
const path = require('path');
const childProcess = require('child_process');

const channel = String(process.argv[2] || '').trim().toLowerCase();

if (channel !== 'beta' && channel !== 'stable') {
  console.error('Usage: node scripts/next_release_version.js <beta|stable>');
  process.exit(1);
}

function run(command) {
  return childProcess.execSync(command, {
    cwd: process.cwd(),
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
  }).trim();
}

function parseVersion(value) {
  const match = String(value || '').trim().match(
    /^v?(\d+)\.(\d+)\.(\d+)(?:-beta\.(\d+))?$/
  );
  if (!match) {
    return null;
  }

  return {
    major: Number(match[1]),
    minor: Number(match[2]),
    patch: Number(match[3]),
    beta: match[4] == null ? null : Number(match[4]),
  };
}

function compareBase(left, right) {
  for (const key of ['major', 'minor', 'patch']) {
    if (left[key] !== right[key]) {
      return left[key] - right[key];
    }
  }
  return 0;
}

function compareVersion(left, right) {
  const baseComparison = compareBase(left, right);
  if (baseComparison !== 0) {
    return baseComparison;
  }

  const leftBeta = left.beta == null ? Number.POSITIVE_INFINITY : left.beta;
  const rightBeta = right.beta == null ? Number.POSITIVE_INFINITY : right.beta;
  return leftBeta - rightBeta;
}

function formatBase(version) {
  return `${version.major}.${version.minor}.${version.patch}`;
}

function formatVersion(version) {
  if (version.beta == null) {
    return formatBase(version);
  }
  return `${formatBase(version)}-beta.${version.beta}`;
}

function patchBump(version) {
  return {
    major: version.major,
    minor: version.minor,
    patch: version.patch + 1,
    beta: null,
  };
}

function maxBase(left, right) {
  return compareBase(left, right) >= 0 ? left : right;
}

function readPackageVersion() {
  const packageJsonPath = path.join(process.cwd(), 'package.json');
  const packageJson = JSON.parse(fs.readFileSync(packageJsonPath, 'utf8'));
  const version = parseVersion(packageJson.version);
  if (!version) {
    throw new Error(`Unsupported package.json version: ${packageJson.version}`);
  }
  return version;
}

function listTags(pattern) {
  const output = run(`git tag --list '${pattern}' --sort=-v:refname`);
  if (!output) {
    return [];
  }
  return output
    .split('\n')
    .map((line) => line.trim())
    .filter(Boolean);
}

function listStableVersions() {
  return listTags('v[0-9]*.[0-9]*.[0-9]*')
    .map((tag) => parseVersion(tag))
    .filter((version) => version && version.beta == null)
    .sort((left, right) => compareVersion(right, left));
}

function listBetaVersions(baseLabel) {
  return listTags(`v${baseLabel}-beta.*`)
    .map((tag) => parseVersion(tag))
    .filter((version) => version && version.beta != null)
    .sort((left, right) => compareVersion(right, left));
}

function resolveNextBetaVersion(packageVersion, latestStable) {
  const packageBase = {
    major: packageVersion.major,
    minor: packageVersion.minor,
    patch: packageVersion.patch,
    beta: null,
  };
  const minimumBase = latestStable ? patchBump(latestStable) : packageBase;
  const baseVersion = maxBase(packageBase, minimumBase);
  const baseLabel = formatBase(baseVersion);
  const betaVersions = listBetaVersions(baseLabel);
  const nextBetaNumber = betaVersions.length > 0 ? betaVersions[0].beta + 1 : 0;

  return {
    version: {
      major: baseVersion.major,
      minor: baseVersion.minor,
      patch: baseVersion.patch,
      beta: nextBetaNumber,
    },
    baseVersion,
  };
}

function resolveNextStableVersion(packageVersion, latestStable) {
  const packageBase = {
    major: packageVersion.major,
    minor: packageVersion.minor,
    patch: packageVersion.patch,
    beta: null,
  };

  if (!latestStable) {
    return packageBase;
  }

  if (compareBase(packageBase, latestStable) <= 0) {
    return patchBump(latestStable);
  }

  return packageBase;
}

function writeOutputs(result) {
  const outputPath = process.env.GITHUB_OUTPUT;
  if (!outputPath) {
    return;
  }

  const lines = [
    `channel=${result.channel}`,
    `version=${result.version}`,
    `release_tag=${result.releaseTag}`,
    `base_version=${result.baseVersion}`,
  ];
  fs.appendFileSync(outputPath, `${lines.join('\n')}\n`);
}

const packageVersion = readPackageVersion();
const latestStable = listStableVersions()[0] || null;
let resolvedVersion;
let resolvedBaseVersion;

if (channel === 'beta') {
  const nextBeta = resolveNextBetaVersion(packageVersion, latestStable);
  resolvedVersion = nextBeta.version;
  resolvedBaseVersion = nextBeta.baseVersion;
} else {
  resolvedVersion = resolveNextStableVersion(packageVersion, latestStable);
  resolvedBaseVersion = {
    major: resolvedVersion.major,
    minor: resolvedVersion.minor,
    patch: resolvedVersion.patch,
    beta: null,
  };
}

const result = {
  channel,
  version: formatVersion(resolvedVersion),
  releaseTag: `v${formatVersion(resolvedVersion)}`,
  baseVersion: formatBase(resolvedBaseVersion),
};

writeOutputs(result);
process.stdout.write(`${JSON.stringify(result)}\n`);
