<p align="center">
  <img src="landing/assets/logo.svg" width="112" height="112" alt="NeoRecall">
</p>

<h1 align="center">NeoRecall</h1>

<p align="center"><strong>Private, self-hosted audio memory — recorded anywhere, transcribed locally, and recalled naturally.</strong></p>

<p align="center">
  NeoRecall runs as a service on your own machine. It transcribes and diarizes
  audio from web, desktop, and wearable clients entirely on-device, builds
  searchable local memory, and only calls an LLM for rare, budgeted
  consolidation and Ask queries.
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
npm i -g neorecall
neorecall install
neorecall setup
neorecall start
```

Open `http://localhost:4500` and `/app/`. Use `neorecall update` to install newer GitHub releases for the setup-selected `beta` or `stable` channel.

Read the [installation guide](docs/docs/installation.md) before exposing the service to a network.

## ✨ What makes it different

- **Audio stays under your control.** Clients retain every chunk until the server proves its transcript is durable and its temporary audio copy is gone.
- **Transcription and search are local.** CPU inference, multilingual embeddings, FTS5, and sqlite-vec keep the continuous path free of paid tokens.
- **LLMs are rare and budgeted.** OpenRouter is called only for eligible memory consolidations, live conversation previews, and explicit Ask searches, with durable rate gates.
- **Built for recorders that never stop.** Audio uploads, transcription, and conversation detection all run during capture, a conversation that is still recording gets a provisional title and summary you can read before it ends, and one real-world occasion still becomes exactly one memory.
- **Offline first.** Browser and desktop clients buffer independently decodable chunks and resume idempotent uploads when the server returns.
- **Native NeoAgent recall.** Connect from [NeoAgent](https://github.com/NeoLabs-Systems/NeoAgent) with PKCE OAuth to search memories and transcript evidence through read-only, token-free retrieval tools.

## 🧪 Project status

NeoRecall is beta software maintained primarily by one person. Web, macOS 13+, and Windows 10/11 x64 are the v1 clients. Desktop is the reference client for uninterrupted recording; browser capture remains subject to browser permission and lifecycle limits. Review [Privacy and consent](docs/docs/privacy-and-consent.md) before recording anyone else.

## 📚 Documentation

Start with the [documentation](https://neolabs-systems.github.io/NeoRecall/docs/).
Use [GitHub Discussions](https://github.com/NeoLabs-Systems/NeoRecall/discussions)
for questions and [GitHub Issues](https://github.com/NeoLabs-Systems/NeoRecall/issues)
for reproducible bugs. Security reports belong in the process described by
[SECURITY.md](SECURITY.md).

## License

NeoRecall is licensed under the
[GNU Affero General Public License v3.0 only](LICENSE).

*Made with ❤️ by [Neo](https://github.com/neooriginal) · [NeoLabs Systems](https://github.com/NeoLabs-Systems)*
