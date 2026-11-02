'use strict';

// Administration, end to end, against a real server and worker: who reaches the
// admin API, everything the app's Admin page does through it, the operator CLI
// on a running server, and what a restart does with NEORECALL_ADMIN_USERS and
// the retired dashboard credentials.

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');
const { assert, api: request, runScenario, startServer } = require('./lib/e2e_harness');

const repositoryRoot = path.join(__dirname, '..');
const sourceModels = path.resolve(process.env.NEORECALL_E2E_MODELS || path.join(os.homedir(), '.neorecall', 'models'));
const timeoutMs = Number(process.env.NEORECALL_E2E_TIMEOUT_MS || 5 * 60_000);
const version = require('../package.json').version;

const suffix = crypto.randomUUID().slice(0, 6);
const password = `E2E-${crypto.randomBytes(18).toString('base64url')}`;
const names = { owner: `owner-${suffix}`, member: `member-${suffix}`, listed: `listed-${suffix}`, reserved: `reserved-${suffix}` };

// The provider self-test asks the model for a one-word JSON answer; the mock
// classifies that request as "unknown" and this handler answers it.
const mockHandlers = { unknown: () => ({ answer: 'ready' }) };

/// Expects the request to be refused with `status` and, when given, `code`.
async function refused(label, status, code, operation) {
  try {
    await operation();
  } catch (error) {
    assert(error.status === status, `${label}: expected ${status}, got ${error.status} (${error.message})`);
    if (code) assert(error.value?.error?.code === code, `${label}: expected ${code}, got ${error.value?.error?.code}`);
    return;
  }
  throw new Error(`${label}: expected ${status}${code ? ` ${code}` : ''}, but the request succeeded`);
}

function cli(home, ...args) {
  const result = spawnSync(process.execPath, [path.join(repositoryRoot, 'bin', 'neorecall.js'), 'admin', ...args, '--json'], {
    cwd: repositoryRoot,
    encoding: 'utf8',
    env: { ...process.env, NEORECALL_HOME: home },
  });
  assert(result.status === 0, `neorecall admin ${args.join(' ')} failed: ${result.stderr}`);
  return JSON.parse(result.stdout.trim().split('\n').pop());
}

/// Writes one job straight into the server's database, the way a failed piece
/// of work looks after its last attempt. The type is one no worker handles, so
/// running it again ends the same way without touching anything else.
function insertFailedJob(home) {
  const id = crypto.randomUUID();
  const script = `
    const db = require('./server/db/database').getDatabase();
    const now = new Date().toISOString();
    db.prepare(\`INSERT INTO jobs (id,type,status,priority,attempts,max_attempts,next_attempt_at,payload_json,
      last_error_code,last_error_message,created_at,updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)\`)
      .run(${JSON.stringify(id)}, 'e2e_admin_probe', 'failed', 0, 5, 5, now, '{}', 'E2E_PROBE', 'Inserted by the admin E2E run.', now, now);`;
  const result = spawnSync(process.execPath, ['-e', script], {
    cwd: repositoryRoot, encoding: 'utf8', env: { ...process.env, NEORECALL_HOME: home },
  });
  assert(result.status === 0, `Could not insert the probe job: ${result.stderr}`);
  return id;
}

async function main() {
  await runScenario('admin', { sourceModels, timeoutMs, mockHandlers }, async ({ baseUrl, api, poll, mock, say, home, stop }) => {
    const register = async (username) => {
      const value = await api('POST', '/api/v1/auth/register', null, { username, password });
      return { id: value.user.id, role: value.user.role, token: value.session.token };
    };

    say('the first account is the admin; the next one is not');
    const owner = await register(names.owner);
    const member = await register(names.member);
    assert(owner.role === 'admin', `The first account got role ${owner.role}.`);
    assert(member.role === 'user', `The second account got role ${member.role}.`);

    say('only an admin session reaches the admin API');
    await refused('anonymous', 401, 'AUTHENTICATION_REQUIRED', () => api('GET', '/api/v1/admin/stats'));
    await refused('ordinary account', 403, 'ADMIN_REQUIRED', () => api('GET', '/api/v1/admin/stats', member.token));
    const key = await api('POST', '/api/v1/api-keys', owner.token, { name: 'e2e everything', scopes: ['*'] });
    await refused('admin API key', 403, 'SESSION_REQUIRED', () => api('GET', '/api/v1/admin/users', key.token));
    const stats = await poll('a worker heartbeat on the overview',
      () => api('GET', '/api/v1/admin/stats', owner.token),
      (value) => value.workers.some((worker) => worker.model_state === 'ready'));
    assert(stats.version === version, `Overview reports version ${stats.version}, expected ${version}.`);
    assert(stats.users === 2, `Overview counts ${stats.users} accounts.`);

    say('the retired dashboard addresses lead to the app, and its API says where it went');
    for (const route of ['/admin', '/admin/login.html']) {
      const response = await fetch(`${baseUrl}${route}`, { redirect: 'manual', headers: { Authorization: `Bearer ${owner.token}` } });
      assert(response.status === 302 && response.headers.get('location') === '/app/', `${route} answered ${response.status}.`);
    }
    await refused('the retired admin API', 410, 'ADMIN_API_MOVED', () => api('GET', '/admin/api/v1/stats', owner.token));

    say('accounts: disabling signs a person out, and admin accounts are refused');
    const users = await api('GET', '/api/v1/admin/users', owner.token);
    assert(users.users.find((user) => user.id === owner.id)?.role === 'admin', 'The users list does not mark the admin.');
    await refused('disabling the admin itself', 403, 'ADMIN_ACCOUNT',
      () => api('PATCH', `/api/v1/admin/users/${owner.id}`, owner.token, { disabled: true }));
    await api('PATCH', `/api/v1/admin/users/${member.id}`, owner.token, { disabled: true });
    await refused('a disabled account’s session', 401, null, () => api('GET', '/api/v1/auth/me', member.token));
    await refused('a disabled account signing in', 403, 'ACCOUNT_DISABLED',
      () => api('POST', '/api/v1/auth/login', null, { account: names.member, password }));
    await api('PATCH', `/api/v1/admin/users/${member.id}`, owner.token, { disabled: false });
    member.token = (await api('POST', '/api/v1/auth/login', null, { account: names.member, password })).session.token;

    say('usage limits for everyone and for one account');
    const install = await api('PUT', '/api/v1/admin/config/usage-limits', owner.token, { aiTokens4h: 123456 });
    assert(install.limits.aiTokens4h === 123456, 'The install limit did not save.');
    const own = await api('PUT', `/api/v1/admin/users/${member.id}/usage-limits`, owner.token,
      { aiLimit4h: null, aiLimitWeekly: 0, transcriptionLimit4h: 600, transcriptionLimitWeekly: null });
    assert(own.aiLimitWeekly === 0 && own.transcriptionLimit4h === 600 && own.aiLimit4h === null, 'The account limits did not save.');
    const usage = await api('GET', '/api/v1/auth/account/usage', member.token);
    assert(usage.transcription.limits.fourHour === 600, 'The account does not see its own transcription cap.');
    assert(usage.ai.limits.fourHour === 123456, 'The account does not inherit the install AI cap.');

    say('providers: saved from the admin session, never returned, and tested for real');
    const mockUrl = `http://127.0.0.1:${mock.server.address().port}/v1`;
    const secret = `sk-e2e-${crypto.randomBytes(12).toString('hex')}`;
    const saved = await api('PUT', '/api/v1/admin/provider-settings', owner.token, {
      llm: { provider: 'openai_compatible', model: 'e2e/admin-model', baseUrl: mockUrl, apiKey: secret,
        extraBody: { chat_template_kwargs: { enable_thinking: false } } },
      transcription: { provider: 'openai-compatible', model: 'e2e/mock-asr', baseUrl: mockUrl, language: 'de', responseFormat: 'verbose_json' },
    });
    assert(!JSON.stringify(saved).includes(secret), 'A saved provider key came back in the response.');
    assert(saved.settings.llm.apiKeySource === 'admin', 'The saved key is not reported as saved from the app.');
    assert(saved.settings.llm.extraBody?.chat_template_kwargs?.enable_thinking === false, 'Extra request JSON did not save.');
    assert(saved.settings.transcription.language === 'de', 'The transcription language did not save.');
    const reread = await api('GET', '/api/v1/admin/provider-settings', owner.token);
    assert(!JSON.stringify(reread).includes(secret), 'A saved provider key is readable through the API.');
    const test = await api('POST', '/api/v1/admin/provider-settings/test', owner.token);
    assert(test.transcription.ok, `The transcription leg failed: ${test.transcription.error}`);
    assert(test.llm.ok && test.llm.answer === 'ready', `The language-model leg failed: ${test.llm.error}`);
    const probe = mock.of('unknown').at(-1);
    assert(probe?.payload?.model === 'e2e/admin-model', 'The self-test did not use the model saved from the app.');
    assert(probe.payload.chat_template_kwargs?.enable_thinking === false, 'The self-test request did not carry the extra JSON.');
    const reset = await api('DELETE', '/api/v1/admin/provider-settings', owner.token);
    assert(reset.settings.llm.sources.model === 'environment' && reset.settings.llm.apiKeySource !== 'admin',
      'Resetting providers did not hand them back to the environment.');

    say('processing thresholds: one change saved, a bad value refused per field');
    const before = (await api('GET', '/api/v1/admin/processing-settings', owner.token)).settings;
    const nextSimilarity = before.dedupeTokenSimilarity >= 0.95 ? 0.9 : Number((before.dedupeTokenSimilarity + 0.01).toFixed(4));
    const changed = await api('PUT', '/api/v1/admin/processing-settings', owner.token, { dedupeTokenSimilarity: nextSimilarity });
    assert(changed.settings.dedupeTokenSimilarity === nextSimilarity, 'The threshold did not save.');
    try {
      await api('PUT', '/api/v1/admin/processing-settings', owner.token, { dedupeTokenSimilarity: 5 });
      throw new Error('An out-of-range threshold was accepted.');
    } catch (error) {
      assert(error.status === 400 && error.value?.error?.details?.fieldErrors?.dedupeTokenSimilarity,
        `An out-of-range threshold was not refused per field: ${error.message}`);
    }

    say('jobs: a failed one runs again through the worker, another is cancelled');
    const retried = insertFailedJob(home);
    const cancelled = insertFailedJob(home);
    await api('POST', `/api/v1/admin/jobs/${retried}/retry`, owner.token);
    await api('POST', `/api/v1/admin/jobs/${cancelled}/cancel`, owner.token);
    await refused('cancelling a cancelled job', 409, 'JOB_NOT_CANCELLABLE',
      () => api('POST', `/api/v1/admin/jobs/${cancelled}/cancel`, owner.token));
    await poll('the retried job running again', () => api('GET', '/api/v1/admin/jobs?limit=500', owner.token), (value) => {
      const job = value.jobs.find((entry) => entry.id === retried);
      return job?.status === 'failed' && job.attempts === 1 && job.last_error_code === 'UNKNOWN_JOB_TYPE';
    });
    const jobs = await api('GET', '/api/v1/admin/jobs?limit=500', owner.token);
    assert(jobs.jobs.find((entry) => entry.id === cancelled)?.status === 'cancelled', 'The cancelled job is not cancelled.');

    say('backups: one run from the Admin page lands in the history');
    const backup = await api('POST', '/api/v1/admin/backups/run', owner.token);
    assert(backup.key && backup.bytes > 0, 'The backup did not write an artifact.');
    // A fresh install is due a backup, so the worker may have taken its own
    // scheduled one alongside; this run's artifact is the one asserted on.
    const backups = await api('GET', '/api/v1/admin/backups', owner.token);
    const entry = backups.history.find((row) => row.artifact_key === backup.key);
    assert(entry?.state === 'succeeded' && entry.trigger_kind === 'manual' && backups.status.artifactCount >= 1,
      `The backup is not in the history: ${JSON.stringify(backups.history)}`);

    say('the audit log names who did what');
    const audit = await api('GET', '/api/v1/admin/audit?limit=200', owner.token);
    const disabledEntry = audit.entries.find((entry) => entry.action === 'user_disabled');
    assert(disabledEntry?.actor_type === 'admin' && disabledEntry.actor_username === names.owner
      && disabledEntry.affected_username === names.member, 'The audit log does not name the admin and the account.');
    for (const action of ['user_usage_limits_updated', 'provider_settings_updated', 'provider.test', 'provider_settings_reset',
      'processing_settings_updated', 'backup_run']) {
      assert(audit.entries.some((entry) => entry.action === action), `The audit log has no ${action} entry.`);
    }
    assert(!JSON.stringify(audit).includes(secret), 'A provider key reached the audit log.');

    say('an admin cannot delete their own account');
    await refused('admin self-delete', 403, 'ADMIN_SELF_DELETE', () => api('DELETE', '/api/v1/auth/account', owner.token, { password }));

    say('the CLI grants and revokes admin on the running server, effective at once');
    assert(JSON.stringify(cli(home).admins) === JSON.stringify([names.owner]), 'The CLI lists the wrong admins.');
    assert(cli(home, 'grant', names.member).changed === true, 'The CLI grant reported no change.');
    await api('GET', '/api/v1/admin/stats', member.token);
    assert((await api('GET', '/api/v1/auth/me', member.token)).user.role === 'admin', 'The granted account does not see its role.');
    assert(cli(home, 'revoke', names.member).changed === true, 'The CLI revoke reported no change.');
    await refused('a revoked admin', 403, 'ADMIN_REQUIRED', () => api('GET', '/api/v1/admin/stats', member.token));
    const afterCli = await api('GET', '/api/v1/admin/audit?limit=200', owner.token);
    const cliEntries = afterCli.entries.filter((entry) => ['admin_granted', 'admin_revoked'].includes(entry.action)
      && entry.affected_username === names.member);
    assert(cliEntries.length === 2 && cliEntries.every((entry) => entry.actor_type === 'system'), 'The CLI changes are not audited.');

    say('a restart applies NEORECALL_ADMIN_USERS and retires the old dashboard credentials');
    const listed = await register(names.listed);
    fs.appendFileSync(path.join(home, '.env'), 'ADMIN_USERNAME=admin\nADMIN_PASSWORD=an-old-dashboard-password\nADMIN_API_KEY=an-old-admin-api-key\n');
    await stop({ keepHome: true });
    const restarted = await startServer({
      label: 'admin-restart', home, sourceModels, timeoutMs, mockHandlers,
      env: { NEORECALL_ADMIN_USERS: `${names.listed}, ${names.reserved}` },
    });
    try {
      await restarted.poll('HTTP restart', () => fetch(`${restarted.baseUrl}/health`), (response) => response.ok);
      const again = (method, route, token, body) => request(restarted.baseUrl, method, route, token, body);
      assert((await again('GET', '/api/v1/auth/me', listed.token)).user.role === 'admin', 'NEORECALL_ADMIN_USERS did not grant admin.');
      await again('GET', '/api/v1/admin/stats', listed.token);
      const envFile = fs.readFileSync(path.join(home, '.env'), 'utf8');
      assert(!/^ADMIN_(USERNAME|PASSWORD|API_KEY)=/m.test(envFile), 'The retired dashboard credentials are still in the env file.');
      await refused('the old admin API key', 401, 'AUTHENTICATION_REQUIRED',
        () => again('GET', '/api/v1/admin/stats', 'an-old-admin-api-key'));
      await refused('registering a reserved admin name', 409, 'USERNAME_RESERVED',
        () => again('POST', '/api/v1/auth/register', null, { username: names.reserved.toUpperCase(), password }));
      const logs = await restarted.poll('the startup notices', async () => restarted.logs(), (value) =>
        value.includes('Removed retired admin dashboard credentials') && value.includes('names accounts that do not exist')
        && value.includes('"message":"Admin accounts"'));
      // Retired by the supervisor before the children start, so neither child
      // reports the keys as still set in its environment.
      assert(!logs.includes('Ignoring retired admin dashboard credentials'), 'A child still inherited the retired credentials.');
    } finally {
      await restarted.stop({ keepHome: true });
    }
    say('admin passed');
  });
}

main().catch((error) => {
  process.stderr.write(`${error.stack || error.message}\n`);
  process.exitCode = 1;
});
