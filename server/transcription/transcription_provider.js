'use strict';

class TranscriptionProvider {
  async transcribe(_input) { throw new Error('TranscriptionProvider.transcribe must be implemented.'); }
  async ready() { return false; }
}

module.exports = { TranscriptionProvider };
