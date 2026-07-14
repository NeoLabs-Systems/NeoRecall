'use strict';

function nowIso() { return new Date().toISOString(); }
function addMilliseconds(iso, milliseconds) { return new Date(new Date(iso).getTime() + milliseconds).toISOString(); }
function clamp(value, min, max) { return Math.min(max, Math.max(min, value)); }
function isIanaTimezone(value) {
  try { new Intl.DateTimeFormat('en', { timeZone: value }).format(); return true; } catch { return false; }
}

function localDateTimeParts(instantMs, timezone) {
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone: timezone, year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', second: '2-digit', hourCycle: 'h23',
  }).formatToParts(new Date(instantMs));
  return Object.fromEntries(parts.map((part) => [part.type, part.value]));
}

function localDateTimeToUtc(localDateTime, timezone) {
  if (!isIanaTimezone(timezone)) throw new Error(`Invalid IANA timezone: ${timezone}.`);
  const match = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})$/.exec(String(localDateTime));
  if (!match) throw new Error('Local date-time must use YYYY-MM-DDTHH:mm:ss without an offset.');
  const target = match.slice(1).map(Number);
  const targetAsUtc = Date.UTC(target[0], target[1] - 1, target[2], target[3], target[4], target[5]);
  if (new Date(targetAsUtc).toISOString().slice(0, 19) !== localDateTime) throw new Error('Local date-time is not a valid calendar value.');
  let candidate = targetAsUtc;
  for (let attempt = 0; attempt < 4; attempt += 1) {
    const local = localDateTimeParts(candidate, timezone);
    const represented = Date.UTC(Number(local.year), Number(local.month) - 1, Number(local.day), Number(local.hour), Number(local.minute), Number(local.second));
    const correction = targetAsUtc - represented;
    if (correction === 0) return new Date(candidate).toISOString();
    candidate += correction;
  }
  throw new Error(`Local date-time ${localDateTime} does not resolve uniquely in ${timezone}.`);
}

module.exports = { nowIso, addMilliseconds, clamp, isIanaTimezone, localDateTimeToUtc };
