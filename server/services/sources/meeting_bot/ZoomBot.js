'use strict';

const AbstractBot = require('./AbstractBot');

class ZoomBot extends AbstractBot {
  async joinMeeting() {
    console.log(`[ZoomBot] Joining ${this.url}`);
    
    // Zoom URLs often look like https://zoom.us/j/123456789?pwd=...
    // The web client URL is https://zoom.us/wc/join/123456789
    let wcUrl = this.url;
    if (this.url.includes('/j/')) {
      wcUrl = this.url.replace('/j/', '/wc/join/');
    }

    await this.page.goto(wcUrl, { waitUntil: 'domcontentloaded' });
    
    // 1. Accept Cookies
    try {
      const acceptCookies = this.page.locator('#onetrust-accept-btn-handler');
      await acceptCookies.waitFor({ state: 'visible', timeout: 5000 });
      await acceptCookies.click();
    } catch (e) {}

    // 2. Type Name
    const nameInput = this.page.locator('input[name="inputname"]');
    await nameInput.waitFor({ state: 'visible', timeout: 15000 });
    await nameInput.fill(this.botName);

    // 3. Join Button
    const joinBtn = this.page.locator('button#joinBtn');
    await joinBtn.click();
    
    console.log(`[ZoomBot] Clicked Join, waiting for admission...`);
    
    // 4. Accept Audio / Join Audio by Computer
    try {
      const joinAudioBtn = this.page.locator('button:has-text("Join Audio by Computer")');
      await joinAudioBtn.waitFor({ state: 'visible', timeout: 60000 });
      await joinAudioBtn.click();
    } catch (e) {
      console.log(`[ZoomBot] Join audio button not found, might already be connected.`);
    }

    console.log(`[ZoomBot] Admitted to meeting!`);
    this.isRecording = true;
    
    // Start audio capture
    await this.page.evaluate(() => {
       if (window.startAudioCapture) window.startAudioCapture();
    });
  }
}

module.exports = ZoomBot;
