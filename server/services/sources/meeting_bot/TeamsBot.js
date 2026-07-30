'use strict';

const AbstractBot = require('./AbstractBot');

class TeamsBot extends AbstractBot {
  async joinMeeting() {
    console.log(`[TeamsBot] Joining ${this.url}`);
    
    await this.page.goto(this.url, { waitUntil: 'domcontentloaded' });
    
    // 1. "Continue on this browser"
    try {
      const continueBtn = this.page.locator('button[data-tid="joinOnWeb"]');
      await continueBtn.waitFor({ state: 'visible', timeout: 15000 });
      await continueBtn.click();
    } catch (e) {
      console.log(`[TeamsBot] Continue on web button not found, maybe already there.`);
    }

    // Teams uses an iframe for the meeting view
    // 2. Wait for name input
    const frame = this.page.frameLocator('iframe[name="experience-container-frame"]');
    let nameInput = null;
    
    try {
      nameInput = frame.locator('input[placeholder*="name" i], input[aria-label*="name" i]');
      await nameInput.waitFor({ state: 'visible', timeout: 20000 });
    } catch (e) {
      nameInput = this.page.locator('input[placeholder*="name" i], input[aria-label*="name" i]');
      await nameInput.waitFor({ state: 'visible', timeout: 20000 });
    }

    await nameInput.fill(this.botName);

    // 3. Click Join Now
    let joinBtn = null;
    try {
      joinBtn = frame.locator('button:has-text("Join now")');
      await joinBtn.waitFor({ state: 'visible', timeout: 5000 });
    } catch (e) {
      joinBtn = this.page.locator('button:has-text("Join now")');
    }
    
    await joinBtn.click();
    console.log(`[TeamsBot] Clicked Join, waiting for admission...`);
    
    // 4. Wait to be admitted
    await this.page.waitForFunction(() => document.querySelectorAll('audio, video').length > 0, { timeout: 60000 });
    
    console.log(`[TeamsBot] Admitted to meeting!`);
    this.isRecording = true;
    
    // Start audio capture
    await this.page.evaluate(() => {
       if (window.startAudioCapture) window.startAudioCapture();
    });
  }
}

module.exports = TeamsBot;
