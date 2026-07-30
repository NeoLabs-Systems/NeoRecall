'use strict';

const AbstractBot = require('./AbstractBot');

class GoogleMeetBot extends AbstractBot {
  async joinMeeting() {
    console.log(`[GoogleMeetBot] Joining ${this.url}`);
    
    // Go to meeting URL
    await this.page.goto(this.url, { waitUntil: 'domcontentloaded' });
    
    // 1. Wait for name input or "Continue without microphone" dialogs
    try {
      const continueWithoutMic = this.page.locator('button:has-text("Continue without microphone and camera")');
      await continueWithoutMic.waitFor({ timeout: 5000 });
      await continueWithoutMic.click();
    } catch (e) {
      // Ignore if not present
    }

    try {
      const gotIt = this.page.locator('button:has-text("Got it")');
      await gotIt.waitFor({ timeout: 2000 });
      await gotIt.click();
    } catch (e) {}

    // 2. Type Name
    const nameInput = this.page.locator('input[type="text"][placeholder*="name" i]');
    await nameInput.waitFor({ state: 'visible', timeout: 15000 });
    await nameInput.fill(this.botName);

    // 3. Ask to join
    const askToJoinBtn = this.page.locator('button:has-text("Ask to join")');
    await askToJoinBtn.waitFor({ state: 'visible', timeout: 5000 });
    await askToJoinBtn.click();
    
    console.log(`[GoogleMeetBot] Asked to join, waiting for admission...`);
    
    // 4. Wait to be admitted (e.g. check for meeting controls)
    const meetingControls = this.page.locator('button[aria-label="Turn off microphone"]'); // example
    // We can also just wait for the URL to change or for audio elements to appear
    await this.page.waitForFunction(() => document.querySelectorAll('audio, video').length > 0, { timeout: 60000 });
    
    console.log(`[GoogleMeetBot] Admitted to meeting!`);
    this.isRecording = true;
    
    // Start audio capture script (defined in AbstractBot)
    await this.page.evaluate(() => {
       if (window.startAudioCapture) window.startAudioCapture();
    });
  }
}

module.exports = GoogleMeetBot;
