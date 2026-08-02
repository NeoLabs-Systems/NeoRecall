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
  humanPause,
} = require('./meet_helpers');

// Google Meet renders in the account/browser locale, so list every text we act
// on in the locales we support (English + German). Add locales here.
const CONTINUE_WITHOUT_DEVICES = ['Continue without microphone and camera', 'Ohne Mikrofon und Kamera fortfahren'];
const JOIN_BUTTONS = ['Ask to join', 'Join now', 'Join anyway', 'Teilnahme erbitten', 'Jetzt teilnehmen', 'Trotzdem teilnehmen'];
const CANNOT_JOIN = ["You can't join this video call", 'Sie können nicht an diesem Videoanruf teilnehmen'];
const MUTE_TOGGLES = [
  { name: 'microphone', re: /Turn off microphone|Mikrofon deaktivieren/i },
  { name: 'camera', re: /Turn off camera|Kamera deaktivieren/i },
];
const ADMITTED_SELECTOR = 'button[aria-label*="Leave call" i], button[aria-label*="Anruf verlassen" i]';

class GoogleMeetBot extends AbstractBot {
  admittedSelector() { return ADMITTED_SELECTOR; }

  async joinMeeting() {
    console.log(`[GoogleMeetBot] Joining ${this.url}`);
    await this.page.goto(this.url, { waitUntil: 'domcontentloaded' });

    await clickButtonByTexts(this.page, CONTINUE_WITHOUT_DEVICES);
    await this._failIfRefused();

    // Guests are asked for a display name; a signed-in browser is not, because
    // Meet uses the account's name. Both are valid pre-join states — a signed-in
    // join only glances for the field rather than waiting the full guest budget.
    const named = await fillDisplayNameIfPresent(this.page, sanitizeDisplayName(this.botName), {
      timeoutMs: this.connection.connected.google ? 3000 : 12000,
    });
    console.log(named
      ? '[GoogleMeetBot] Filled the guest display name.'
      : `[GoogleMeetBot] No name prompt — joining as the signed-in account${this.connection.identity ? ` (${this.connection.identity})` : ''}.`);

    // Passive recorder: force mic + camera off before joining.
    const off = await turnOffToggles(this.page, MUTE_TOGGLES);
    if (off.length) console.log(`[GoogleMeetBot] Turned off: ${off.join(', ')}`);

    await humanPause(this.page);
    // Meet often mounts the join button a moment after the rest of the lobby, so
    // keep looking while watching for a refusal that makes waiting pointless.
    const clicked = await clickButtonByTextsWithin(this.page, JOIN_BUTTONS, {
      onPoll: () => this._failIfRefused(),
    });
    if (!clicked) {
      await this._failIfRefused();
      throw new JoinError('ui_changed', 'Google Meet showed no join button ("Ask to join" / "Teilnahme erbitten") on the pre-join screen. The link may not be a joinable meeting, or Meet changed its lobby.');
    }
    console.log(`[GoogleMeetBot] Clicked "${clicked}", waiting for admission...`);
    await clickButtonByTexts(this.page, CONTINUE_WITHOUT_DEVICES);

    try {
      await waitForAdmission(this.page, {
        admittedSelector: ADMITTED_SELECTOR,
        meetingHost: 'meet.google.com',
        cannotJoinTexts: CANNOT_JOIN,
      });
    } catch (error) {
      throw this._explainRefusal(error);
    }

    console.log('[GoogleMeetBot] Admitted to meeting!');
    this.isRecording = true;
  }

  async _failIfRefused() {
    const hit = await bodyIncludesAny(this.page, CANNOT_JOIN);
    if (hit) throw this._refusalError(`Google Meet refused the join ("${hit}").`);
    if (this.page.url().startsWith('https://accounts.google.com/')) {
      throw this._refusalError('Google Meet sent the bot to the sign-in page, so this meeting is not open to guests.');
    }
  }

  // The same refusal means two different things depending on who the bot is,
  // and the two need opposite fixes — so name the one that applies.
  _refusalError(what) {
    if (this.connection.connected.google) {
      const who = this.connection.identity || 'the connected Google account';
      return new JoinError('not_invited', `${what} ${who} is signed in but not allowed into this meeting — the host restricted it to invited people. Invite ${who} to the meeting, or ask the host to admit it.`);
    }
    return new JoinError('anonymous_blocked', `${what} The bot is joining as an anonymous guest, and this meeting does not accept guests. Connect a Google account under Sources → Meeting account, then start the meeting source again.`);
  }

  _explainRefusal(error) {
    if (error instanceof JoinError && (error.code === 'refused' || error.code === 'redirected')) {
      return this._refusalError(error.message);
    }
    return error;
  }
}

module.exports = GoogleMeetBot;
