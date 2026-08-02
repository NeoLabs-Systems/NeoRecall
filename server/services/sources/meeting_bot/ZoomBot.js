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

const JOIN_AUDIO = ['Join Audio by Computer', 'Join with Computer Audio', 'Per Computer dem Audio beitreten', 'Computeraudio'];
const CANNOT_JOIN = ['This meeting has not started', 'Invalid meeting ID', 'is not valid', 'Dieses Meeting hat noch nicht begonnen'];
const SIGN_IN_REQUIRED = ['Sign in to join', 'authorized attendees', 'Melden Sie sich an', 'autorisierte Teilnehmer'];
const NAME_FIELD = '#input-for-name, input[name="inputname"], input[type="text"]';
const MUTE_TOGGLES = [
  { name: 'microphone', re: /^Mute$|Mute my microphone|Stummschalten/i },
  { name: 'camera', re: /Stop Video|Video beenden/i },
];
const ADMITTED_SELECTOR = 'button[aria-label*="Leave" i], button[aria-label*="Verlassen" i]';

class ZoomBot extends AbstractBot {
  admittedSelector() { return ADMITTED_SELECTOR; }

  async joinMeeting() {
    console.log(`[ZoomBot] Joining ${this.url}`);
    // Prefer the web-client join URL (https://zoom.us/wc/join/<id>).
    const wcUrl = this.url.includes('/j/') ? this.url.replace('/j/', '/wc/join/') : this.url;
    await this.page.goto(wcUrl, { waitUntil: 'domcontentloaded' });

    // OneTrust cookie banner, if present.
    const cookies = this.page.locator('#onetrust-accept-btn-handler');
    if (await cookies.isVisible({ timeout: 5000 }).catch(() => false)) await cookies.click().catch(() => {});

    await this._failIfRefused();
    // Guests type a name; a signed-in Zoom session is not asked for one.
    const named = await fillDisplayNameIfPresent(this.page, sanitizeDisplayName(this.botName), {
      selector: NAME_FIELD,
      timeoutMs: this.connection.connected.zoom ? 4000 : 20000,
    });
    if (!named) console.log(`[ZoomBot] No name prompt — joining as the signed-in account${this.connection.identity ? ` (${this.connection.identity})` : ''}.`);

    const clicked = await clickButtonByTextsWithin(this.page, ['Join', 'Beitreten'], {
      timeoutMs: 20000,
      onPoll: () => this._failIfRefused(),
    });
    if (!clicked) {
      const joinBtn = this.page.locator('button#joinBtn');
      if (await joinBtn.isVisible({ timeout: 3000 }).catch(() => false)) await joinBtn.click();
      else {
        await this._failIfRefused();
        throw new JoinError('ui_changed', 'Zoom showed no Join button on the web client. The meeting may not have started, or Zoom changed its web join page.');
      }
    }
    console.log('[ZoomBot] Clicked join, waiting for admission...');

    try {
      await waitForAdmission(this.page, {
        admittedSelector: ADMITTED_SELECTOR,
        meetingHost: 'zoom.us',
        cannotJoinTexts: CANNOT_JOIN,
      });
    } catch (error) {
      throw this._explainRefusal(error);
    }

    // Connect computer audio so remote audio is audible/capturable, but keep the
    // bot itself muted (mic + camera off).
    await clickButtonByTexts(this.page, JOIN_AUDIO);
    const off = await turnOffToggles(this.page, MUTE_TOGGLES);
    if (off.length) console.log(`[ZoomBot] Turned off: ${off.join(', ')}`);

    console.log('[ZoomBot] Admitted to meeting!');
    this.isRecording = true;
  }

  async _failIfRefused() {
    const needsSignIn = await bodyIncludesAny(this.page, SIGN_IN_REQUIRED);
    if (needsSignIn) throw this._refusalError(`Zoom requires a signed-in participant ("${needsSignIn}").`);
    const refused = await bodyIncludesAny(this.page, CANNOT_JOIN);
    if (refused) throw new JoinError('meeting_unavailable', `Zoom will not open this meeting ("${refused}").`);
  }

  _refusalError(what) {
    if (this.connection.connected.zoom) {
      const who = this.connection.identity || 'the connected Zoom account';
      return new JoinError('not_invited', `${what} ${who} is signed in but not authorised for this meeting — ask the host to invite it or to allow external participants.`);
    }
    return new JoinError('anonymous_blocked', `${what} Connect a Zoom account under Sources → Meeting account, then start the meeting source again.`);
  }

  _explainRefusal(error) {
    if (error instanceof JoinError && (error.code === 'refused' || error.code === 'redirected')) {
      return this._refusalError(error.message);
    }
    return error;
  }
}

module.exports = ZoomBot;
