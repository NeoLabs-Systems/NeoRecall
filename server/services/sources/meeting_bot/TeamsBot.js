'use strict';

const AbstractBot = require('./AbstractBot');
const {
  JoinError,
  clickButtonByTexts,
  clickButtonByTextsWithin,
  fillDisplayNameIfPresent,
  bodyIncludesAny,
  turnOffToggles,
  waitForAdmission,
  sanitizeDisplayName,
} = require('./meet_helpers');

const CONTINUE_ON_WEB = ['Continue on this browser', 'In diesem Browser fortfahren'];
const JOIN_BUTTONS = ['Join now', 'Jetzt teilnehmen'];
const CANNOT_JOIN = ['meeting is full', 'The meeting has ended', 'Das Meeting wurde beendet', 'nicht zulässig'];
const SIGN_IN_REQUIRED = ['Sign in to join this meeting', 'sign in to join', 'Melden Sie sich an, um'];
const NAME_FIELD = 'input[placeholder*="name" i], input[aria-label*="name" i], input[type="text"]';
const MUTE_TOGGLES = [
  { name: 'microphone', re: /^Mute$|Mute microphone|Mikrofon (deaktivieren|stummschalten)/i },
  { name: 'camera', re: /Turn camera off|Kamera deaktivieren/i },
];
const ADMITTED_SELECTOR = 'button[aria-label*="Leave" i], button[aria-label*="Verlassen" i]';

class TeamsBot extends AbstractBot {
  // Teams needs fake media devices to drive its pre-join mic/camera toggles.
  extraChromiumArgs() {
    return ['--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream'];
  }

  admittedSelector() { return ADMITTED_SELECTOR; }

  async joinMeeting() {
    console.log(`[TeamsBot] Joining ${this.url}`);
    await this.page.goto(this.url, { waitUntil: 'domcontentloaded' });

    await clickButtonByTexts(this.page, CONTINUE_ON_WEB);

    // Older Teams builds render the pre-join UI inside an iframe; newer ones are
    // inline. Operate on whichever holds it (Frame and Page share the same API).
    const scope = this.page.frame({ name: 'experience-container-frame' }) || this.page;

    await this._failIfRefused(scope);
    // Anonymous joiners type a name; a signed-in Teams session goes straight
    // through with the account's name.
    const named = await fillDisplayNameIfPresent(scope, sanitizeDisplayName(this.botName), {
      selector: NAME_FIELD,
      timeoutMs: this.connection.connected.microsoft ? 5000 : 25000,
    });
    if (!named) console.log(`[TeamsBot] No name prompt — joining as the signed-in account${this.connection.identity ? ` (${this.connection.identity})` : ''}.`);

    // Passive recorder: mic + camera off before joining.
    const off = await turnOffToggles(scope, MUTE_TOGGLES);
    if (off.length) console.log(`[TeamsBot] Turned off: ${off.join(', ')}`);

    const clicked = await clickButtonByTextsWithin(scope, JOIN_BUTTONS, {
      timeoutMs: 20000,
      onPoll: () => this._failIfRefused(scope),
    });
    if (!clicked) {
      await this._failIfRefused(scope);
      throw new JoinError('ui_changed', 'Teams showed no "Join now" button on the pre-join screen. The link may have expired, or Teams changed its web join page.');
    }
    console.log('[TeamsBot] Clicked join, waiting for admission...');

    try {
      await waitForAdmission(this.page, {
        admittedSelector: ADMITTED_SELECTOR,
        meetingHost: 'teams.',
        cannotJoinTexts: CANNOT_JOIN,
        scope,
      });
    } catch (error) {
      throw this._explainRefusal(error);
    }

    console.log('[TeamsBot] Admitted to meeting!');
    this.isRecording = true;
  }

  async _failIfRefused(scope) {
    const needsSignIn = await bodyIncludesAny(scope, SIGN_IN_REQUIRED);
    if (needsSignIn) throw this._refusalError(`Teams requires a signed-in participant ("${needsSignIn}").`);
    const refused = await bodyIncludesAny(scope, CANNOT_JOIN);
    if (refused) throw new JoinError('meeting_unavailable', `Teams will not open this meeting ("${refused}").`);
  }

  _refusalError(what) {
    if (this.connection.connected.microsoft) {
      const who = this.connection.identity || 'the connected Microsoft account';
      return new JoinError('not_invited', `${what} ${who} is signed in but not admitted to this meeting — ask the host to invite it or to allow anonymous participants.`);
    }
    return new JoinError('anonymous_blocked', `${what} Connect a Microsoft account under Sources → Meeting account, then start the meeting source again.`);
  }

  _explainRefusal(error) {
    if (error instanceof JoinError && (error.code === 'refused' || error.code === 'redirected')) {
      return this._refusalError(error.message);
    }
    return error;
  }
}

module.exports = TeamsBot;
