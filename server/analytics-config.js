'use strict';

const COUNTLY_ENDPOINT = new URL('https://data.neo.eu.com/i');

const config = Object.freeze({
  endpoint: COUNTLY_ENDPOINT.href,
  origin: COUNTLY_ENDPOINT.origin,
  appKey: 'f692479644d216d4224ba5a5da7f3e91ccf8e2e3',
});

function analyticsConfig() {
  const enabled = (process.env.ANALYTICS_ENABLED || '').trim().toLowerCase();
  return ['false', '0', 'off', 'no'].includes(enabled) ? null : config;
}

module.exports = { analyticsConfig };
