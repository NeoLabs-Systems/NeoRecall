'use strict';

const AbstractBot = require('./AbstractBot');
const { clickButtonByTexts, bodyIncludesAny, turnOffToggles, waitForAdmission, sanitizeDisplayName, humanFill } = require('./meet_helpers');

const JOIN_AUDIO = ['Join Audio by Computer', 'Join with Computer Audio', 'Per Computer dem Audio beitreten', 'Computeraudio'];
const CANNOT_JOIN = ['This meeting has not started', 'Invalid meeting ID', 'is not valid', 'Dieses Meeting hat noch nicht begonnen'];
const MUTE_TOGGLES = [
  { name: 'microphone', re: /^Mute$|Mute my microphone|Stummschalten/i },
  { name: 'camera', re: /Stop Video|Video beenden/i },
];
const ADMITTED_SELECTOR = 'button[aria-label*="Leave" i], button[aria-label*="Verlassen" i]';

class ZoomBot extends AbstractBot {
  async joinMeeting() {
    console.log(`[ZoomBot] Joining ${this.url}`);
    // Prefer the web-client join URL (https://zoom.us/wc/join/<id>).
    const wcUrl = this.url.includes('/j/') ? this.url.replace('/j/', '/wc/join/') : this.url;
    await this.page.goto(wcUrl, { waitUntil: 'domcontentloaded' });

    // OneTrust cookie banner, if present.
    const cookies = this.page.locator('#onetrust-accept-btn-handler');
    if (await cookies.isVisible({ timeout: 5000 }).catch(() => false)) await cookies.click().catch(() => {});

    const nameInput = this.page.locator('#input-for-name, input[name="inputname"], input[type="text"]').first();
    try {
      await nameInput.waitFor({ state: 'visible', timeout: 20000 });
    } catch (e) {
      const refused = await bodyIncludesAny(this.page, CANNOT_JOIN);
      throw new Error(`[ZoomBot] Pre-join name field never appeared${refused ? ` ("${refused}")` : ' (Zoom UI change or meeting not started)'}.`);
    }
    await humanFill(nameInput, sanitizeDisplayName(this.botName));

    const clicked = await clickButtonByTexts(this.page, ['Join', 'Beitreten']);
    if (!clicked) {
      const joinBtn = this.page.locator('button#joinBtn');
      if (await joinBtn.isVisible({ timeout: 3000 }).catch(() => false)) await joinBtn.click();
      else throw new Error('[ZoomBot] Could not find the Join button.');
    }
    console.log('[ZoomBot] Clicked join, waiting for admission...');

    await waitForAdmission(this.page, {
      admittedSelector: ADMITTED_SELECTOR,
      meetingHost: 'zoom.us',
      cannotJoinTexts: CANNOT_JOIN,
    });

    // Connect computer audio so remote audio is audible/capturable, but keep the
    // bot itself muted (mic + camera off).
    await clickButtonByTexts(this.page, JOIN_AUDIO);
    const off = await turnOffToggles(this.page, MUTE_TOGGLES);
    if (off.length) console.log(`[ZoomBot] Turned off: ${off.join(', ')}`);

    console.log('[ZoomBot] Admitted to meeting!');
    this.isRecording = true;
  }
}

module.exports = ZoomBot;
