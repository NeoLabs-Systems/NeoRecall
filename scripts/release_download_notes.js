#!/usr/bin/env node
'use strict';

// The download buttons at the top of a GitHub release, like NeoAgent's: one
// shields.io badge per app, linking straight to its file once attached and
// grey "building" until then. Kept between
// two markers so a refresh replaces only this part of the release notes.
//
//   node scripts/release_download_notes.js --tag v1.2.3 [--repo owner/name] [--dry-run]

const { execFileSync } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const DEFAULT_REPOSITORY = 'NeoLabs-Systems/NeoRecall';
const PRODUCT = 'NeoRecall';
const NOTES_START = '<!-- neorecall-download:start -->';
const NOTES_END = '<!-- neorecall-download:end -->';

const APP_SLOTS = [
  { id: 'macos', label: 'macOS', detail: 'app', badgeMessage: 'dmg', logo: 'apple', color: '1c2117', match: /^NeoRecall-macOS-.+\.dmg$/ },
  { id: 'windows-x64', label: 'Windows', detail: 'x64', badgeMessage: 'x64', logo: 'windows', color: '0078d4', match: /^NeoRecall-Windows-x64-.+\.zip$/ },
  { id: 'android', label: 'Android', detail: 'APK', badgeMessage: 'APK', logo: 'android', color: '3ddc84', match: /^NeoRecall-Android-.+\.apk$/ },
  { id: 'wearos', label: 'Wear OS', detail: 'APK', badgeMessage: 'APK', logo: 'wearos', color: '4285f4', match: /^NeoRecall-WearOS-.+\.apk$/ },
];

function githubDownloadUrl(repository, tag, name) {
  return `https://github.com/${repository}/releases/download/${encodeURIComponent(tag)}/${encodeURIComponent(name)}`;
}

function classifyAppAsset(name) {
  return APP_SLOTS.find((slot) => slot.match.test(String(name || ''))) || null;
}

function badgeUrl(label, message, color, logo) {
  return `https://img.shields.io/badge/${encodeURIComponent(label)}-${encodeURIComponent(message)}-${color}`
    + `?style=for-the-badge&logo=${encodeURIComponent(logo)}&logoColor=white`;
}

/** The download section for `tag` from the release's `assets` (`{ name }`). */
function buildDownloadNotes({ tag, repository = DEFAULT_REPOSITORY, assets = [] }) {
  const ready = {};
  for (const asset of assets) {
    const slot = classifyAppAsset(asset && asset.name);
    // The tag's own address, which also holds while a release is a draft.
    if (slot) ready[slot.id] = githubDownloadUrl(repository, tag, asset.name);
  }
  const releaseUrl = `https://github.com/${repository}/releases/tag/${encodeURIComponent(tag)}`;
  const badges = APP_SLOTS.map((slot) => {
    const url = ready[slot.id];
    const image = badgeUrl(slot.label, url ? slot.badgeMessage : 'building', url ? slot.color : '6b7280', slot.logo);
    return `<a href="${url || releaseUrl}"><img alt="${slot.label} ${slot.detail}" src="${image}"></a>`;
  });
  const readyCount = Object.keys(ready).length;
  const status = readyCount === 0
    ? 'The apps are building now. Each one appears here as soon as its build finishes.'
    : readyCount < APP_SLOTS.length
      ? 'Ready apps download in one click. The rest attach as soon as their builds finish.'
      : 'Every app for this release is ready.';
  return [
    NOTES_START,
    '',
    '<p align="center">',
    `  <strong>Download ${PRODUCT} ${tag}</strong>`,
    '</p>',
    '',
    '<p align="center">',
    `  ${badges.join('\n  ')}`,
    '</p>',
    '',
    `<p align="center"><sub>${status}</sub></p>`,
    '',
    '---',
    '',
    NOTES_END,
  ].join('\n');
}

/** `body` with the download section put in (or replaced) at the top. */
function mergeDownloadNotes(body, section) {
  const current = String(body || '').replace(/^﻿/, '');
  const start = current.indexOf(NOTES_START);
  const end = current.indexOf(NOTES_END);
  if (start >= 0 && end > start) {
    const before = current.slice(0, start).replace(/\s*$/, '');
    const after = current.slice(end + NOTES_END.length).replace(/^\s*/, '');
    return `${[before, section.trim(), after].filter(Boolean).join('\n\n').trim()}\n`;
  }
  if (!current.trim()) return `${section.trim()}\n`;
  return `${section.trim()}\n\n${current.replace(/^\s+/, '')}`;
}

function argument(name) {
  const index = process.argv.indexOf(`--${name}`);
  const value = index >= 0 ? process.argv[index + 1] : '';
  return value && !value.startsWith('--') ? value : '';
}

function updateRelease({ tag, repository, dryRun }) {
  // `gh release view` also finds a draft, which the tags API doesn't.
  const release = JSON.parse(execFileSync('gh', ['release', 'view', tag, '--repo', repository, '--json', 'body,assets'], { encoding: 'utf8' }));
  const body = mergeDownloadNotes(release.body, buildDownloadNotes({ tag, repository, assets: release.assets || [] }));
  if (dryRun) {
    process.stdout.write(body);
    return;
  }
  const file = path.join(os.tmpdir(), `neorecall-release-notes-${process.pid}.md`);
  fs.writeFileSync(file, body);
  try {
    execFileSync('gh', ['release', 'edit', tag, '--repo', repository, '--notes-file', file], { stdio: 'inherit' });
  } finally {
    fs.rmSync(file, { force: true });
  }
}

module.exports = { APP_SLOTS, NOTES_END, NOTES_START, buildDownloadNotes, classifyAppAsset, mergeDownloadNotes };

if (require.main === module) {
  const tag = argument('tag');
  if (!tag) throw new Error('--tag is required.');
  updateRelease({ tag, repository: argument('repo') || process.env.GITHUB_REPOSITORY || DEFAULT_REPOSITORY, dryRun: process.argv.includes('--dry-run') });
}
