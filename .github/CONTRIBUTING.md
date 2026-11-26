# Contributing to NeoRecall

## Before you start

- Search existing issues and pull requests before opening a duplicate.
- Keep pull requests focused and target the `beta` branch, not `main`.
- Never include credentials, tokens, recordings, transcripts or other personal data.
- Follow [GUIDELINES.md](GUIDELINES.md).

## Tests

Use the Go version in `go.mod` and Flutter stable.

```bash
gofmt -l cmd internal
go vet ./...
go test -race ./...
```

```bash
cd flutter_app
flutter analyze --no-pub
flutter test --no-pub
```

Changes to authentication, the audio lifecycle, user isolation or voiceprints need
regression tests.

## License

By contributing, you agree that your work is licensed under AGPL-3.0-only.
