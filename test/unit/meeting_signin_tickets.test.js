'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');

const tickets = require('../../server/services/sources/meeting_bot/signin_tickets');

test('a valid ticket redeems exactly once', () => {
  const token = tickets.issue('user-a', 'google');
  assert.deepEqual(tickets.redeem(token), { userId: 'user-a', providerId: 'google' });
  // Single-use: a leaked ticket cannot be replayed for a second connection.
  assert.equal(tickets.redeem(token), null);
});

test('an unknown token is rejected rather than guessed at', () => {
  assert.equal(tickets.redeem('not-a-real-ticket'), null);
});

test('tickets are scoped per user and provider', () => {
  const a = tickets.issue('user-a', 'google');
  const b = tickets.issue('user-b', 'zoom');
  assert.deepEqual(tickets.redeem(a), { userId: 'user-a', providerId: 'google' });
  assert.deepEqual(tickets.redeem(b), { userId: 'user-b', providerId: 'zoom' });
});

test('an expired ticket is refused even though it was issued validly', () => {
  const originalNow = Date.now;
  try {
    let now = originalNow();
    Date.now = () => now;
    const token = tickets.issue('user-a', 'google');
    now += tickets.TICKET_TTL_MS + 1000;
    assert.equal(tickets.redeem(token), null);
  } finally {
    Date.now = originalNow;
  }
});
