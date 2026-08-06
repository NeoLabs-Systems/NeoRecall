<p align="center">
  <img src="landing/assets/logo.svg" width="112" height="112" alt="NeoRecall">
</p>

<h1 align="center">NeoRecall</h1>

<p align="center"><strong>Private, self-hosted audio memory — recorded anywhere, transcribed locally, and recalled naturally.</strong></p>

<p align="center">
  NeoRecall runs as a service on your own machine. It transcribes and diarizes
  audio from web, desktop, and wearable clients entirely on-device, builds
  searchable local memory, and writes that memory with a language model that
  runs on the same machine. No account, no API key, nothing leaves the host.
</p>

<p align="center">
  <a href="https://nodejs.org"><img src="https://img.shields.io/badge/Node.js-20%2B-5fa04e?style=flat-square" alt="Node.js 20 or newer"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-AGPL--3.0-a855f7?style=flat-square" alt="AGPL-3.0 license"></a>
</p>

<p align="center">
  <a href="https://discord.gg/f59rg2RwUT"><img src="https://img.shields.io/badge/Join%20NeoLabs-Discord-5865F2?style=for-the-badge&amp;logo=discord&amp;logoColor=white" alt="Join the NeoLabs Discord"></a>
</p>

<p align="center">
  <a href="https://github.com/NeoLabs-Systems/NeoRecall/releases/latest"><img alt="Web" src="https://img.shields.io/badge/Web-client-000000?style=flat-square"></a>
  <a href="https://github.com/NeoLabs-Systems/NeoRecall/releases/latest"><img alt="macOS" src="https://img.shields.io/badge/macOS-13%2B-000000?style=flat-square&logo=apple&logoColor=white"></a>
  <a href="https://github.com/NeoLabs-Systems/NeoRecall/releases/latest"><img alt="Windows" src="https://img.shields.io/badge/Windows-10%2F11_x64-0078d4?style=flat-square&logo=windows&logoColor=white"></a>
</p>

## 🚀 Install

```bash
npm i -g github:NeoLabs-Systems/NeoRecall
neorecall install
neorecall setup
neorecall start
```

Open `http://localhost:4500` and `/app/`. Use `neorecall update` to install newer GitHub releases for the setup-selected `beta` or `stable` channel.

Read the [installation guide](docs/docs/installation.md) before exposing the service to a network.

## ✨ What makes it different

- **Audio stays under your control.** Clients retain every chunk until the server proves its transcript is durable and its temporary audio copy is gone.
- **Everything runs on your machine.** Speech recognition, diarization, multilingual embeddings, FTS5, sqlite-vec — and the language model that writes your memories. `neorecall setup` downloads all of it; a machine with 16 GB of RAM can run the lot, and any GPU it has is used automatically.
- **Nothing is rationed.** Because generation costs seconds of your own CPU rather than a bill, memories are written as soon as a conversation ends, live previews refresh every minute, and one conversation is read at a time instead of a dozen at once. A transcript longer than the model's context is read in windows and folded back into one memory.
- **Built for recorders that never stop.** Audio uploads, transcription, and conversation detection all run during capture, a conversation that is still recording gets a provisional title and summary you can read before it ends, and one real-world occasion still becomes exactly one memory.
- **Offline first.** Browser and desktop clients buffer independently decodable chunks and resume idempotent uploads when the server returns.
- **Native NeoAgent recall.** Connect from [NeoAgent](https://github.com/NeoLabs-Systems/NeoAgent) to search memories and transcript evidence through read-only, token-free retrieval tools.

## 📚 Documentation

Read the documentation [here](https://neolabs-systems.github.io/NeoRecall/docs/).

Use [GitHub Discussions](https://github.com/NeoLabs-Systems/NeoRecall/discussions)
for questions and [GitHub Issues](https://github.com/NeoLabs-Systems/NeoRecall/issues)
for reproducible bugs. Security reports belong in the process described by
[SECURITY.md](SECURITY.md).

## License

NeoRecall is licensed under the
[GNU Affero General Public License v3.0 only](LICENSE).

*Made with ❤️ by [Neo](https://github.com/neooriginal) · [NeoLabs Systems](https://github.com/NeoLabs-Systems)*
