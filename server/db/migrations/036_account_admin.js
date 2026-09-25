'use strict';

// Admin moved from a separate login -- the `admins` table, its sessions and its
// own two-factor secret -- onto the account role the first registered user
// already receives. Those tables held nothing the account role does not, so they
// go. An install whose only account is not an admin (its first account was
// deleted, say) promotes that account, since it is the person running the
// server; with several accounts and no admin, startup and `neorecall status`
// point at `neorecall admin grant <username>` instead of guessing.
function up(db) {
  const accounts = db.prepare('SELECT id, role FROM users LIMIT 2').all();
  if (accounts.length === 1 && accounts[0].role !== 'admin') {
    db.prepare("UPDATE users SET role = 'admin' WHERE id = ?").run(accounts[0].id);
    db.prepare(`INSERT INTO audit_log (actor_type, affected_user_id, action, metadata_json)
      VALUES ('system', ?, 'admin_granted', ?)`).run(accounts[0].id, JSON.stringify({ source: 'migration' }));
  }
  // Children first: dropping `admins` while its sessions still reference it
  // would run an implicit delete through their foreign keys.
  db.exec(`
    DROP TABLE IF EXISTS admin_recovery_codes;
    DROP TABLE IF EXISTS admin_two_factor;
    DROP TABLE IF EXISTS admin_sessions;
    DROP TABLE IF EXISTS admins;
  `);
}

module.exports = { up };
