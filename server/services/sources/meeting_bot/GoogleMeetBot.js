'use strict';

const AbstractBot = require('./AbstractBot');
const { clickButtonByTexts, bodyIncludesAny, turnOffToggles, waitForAdmission, sanitizeDisplayName, humanPause, humanFill } = require('./meet_helpers');

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
  async joinMeeting() {
    console.log(`[GoogleMeetBot] Joining ${this.url}`);
    await this.page.goto(this.url, { waitUntil: 'domcontentloaded' });

    await clickButtonByTexts(this.page, CONTINUE_WITHOUT_DEVICES);
    await this._failIfRefused();

    // The name field is the only free-text input on the pre-join screen, so match
    // by type rather than a locale-specific placeholder.
    const nameInput = this.page.locator('input[type="text"]').first();
    try {
      await nameInput.waitFor({ state: 'visible', timeout: 20000 });
    } catch (e) {
      await this._failIfRefused();
      throw new Error('[GoogleMeetBot] Pre-join name field never appeared (unsupported page or Meet UI change).');
    }
    await humanFill(nameInput, sanitizeDisplayName(this.botName));

    // Passive recorder: force mic + camera off before joining.
    const off = await turnOffToggles(this.page, MUTE_TOGGLES);
    if (off.length) console.log(`[GoogleMeetBot] Turned off: ${off.join(', ')}`);

    await humanPause(this.page);
    const clicked = await clickButtonByTexts(this.page, JOIN_BUTTONS);
    if (!clicked) throw new Error('[GoogleMeetBot] Could not find a join button (e.g. "Ask to join" / "Teilnahme erbitten").');
    console.log(`[GoogleMeetBot] Clicked "${clicked}", waiting for admission...`);
    await clickButtonByTexts(this.page, CONTINUE_WITHOUT_DEVICES);

    await waitForAdmission(this.page, {
      admittedSelector: ADMITTED_SELECTOR,
      meetingHost: 'meet.google.com',
      cannotJoinTexts: CANNOT_JOIN,
    });

    console.log('[GoogleMeetBot] Admitted to meeting!');
    this.isRecording = true;
  }

  async _failIfRefused() {
    const hit = await bodyIncludesAny(this.page, CANNOT_JOIN);
    if (hit) {
      throw new Error(`[GoogleMeetBot] Google refused the join ("${hit}"). The meeting does not allow anonymous ` +
        `participants, or the host has not started it. This bot joins without a Google account, so meetings ` +
        `restricted to signed-in/invited users cannot be joined.`);
    }
    if (this.page.url().startsWith('https://accounts.google.com/')) {
      throw new Error('[GoogleMeetBot] Meeting requires Google sign-in; the anonymous bot cannot join it.');
    }
  }
}

module.exports = GoogleMeetBot;
