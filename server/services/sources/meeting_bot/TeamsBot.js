'use strict';

const AbstractBot = require('./AbstractBot');
const { clickButtonByTexts, turnOffToggles, waitForAdmission, sanitizeDisplayName, humanFill } = require('./meet_helpers');

const CONTINUE_ON_WEB = ['Continue on this browser', 'In diesem Browser fortfahren'];
const JOIN_BUTTONS = ['Join now', 'Jetzt teilnehmen'];
const CANNOT_JOIN = ['meeting is full', 'The meeting has ended', 'Das Meeting wurde beendet', 'nicht zulässig'];
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

  async joinMeeting() {
    console.log(`[TeamsBot] Joining ${this.url}`);
    await this.page.goto(this.url, { waitUntil: 'domcontentloaded' });

    await clickButtonByTexts(this.page, CONTINUE_ON_WEB);

    // Older Teams builds render the pre-join UI inside an iframe; newer ones are
    // inline. Operate on whichever holds it (Frame and Page share the same API).
    const scope = this.page.frame({ name: 'experience-container-frame' }) || this.page;

    const nameInput = scope.locator('input[placeholder*="name" i], input[aria-label*="name" i], input[type="text"]').first();
    await nameInput.waitFor({ state: 'visible', timeout: 25000 });
    await humanFill(nameInput, sanitizeDisplayName(this.botName));

    // Passive recorder: mic + camera off before joining.
    const off = await turnOffToggles(scope, MUTE_TOGGLES);
    if (off.length) console.log(`[TeamsBot] Turned off: ${off.join(', ')}`);

    const clicked = await clickButtonByTexts(scope, JOIN_BUTTONS);
    if (!clicked) throw new Error('[TeamsBot] Could not find the "Join now" button.');
    console.log('[TeamsBot] Clicked join, waiting for admission...');

    await waitForAdmission(this.page, {
      admittedSelector: ADMITTED_SELECTOR,
      meetingHost: 'teams.',
      cannotJoinTexts: CANNOT_JOIN,
      scope,
    });

    console.log('[TeamsBot] Admitted to meeting!');
    this.isRecording = true;
  }
}

module.exports = TeamsBot;
