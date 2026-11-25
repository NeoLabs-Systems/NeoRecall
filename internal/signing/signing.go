// Package signing provides the public key used for signed runtime manifests.
package signing

import (
	_ "embed"
	"strings"

	"github.com/NeoLabs-Systems/neolabs-go/cli/release"
)

//go:embed public_key.txt
var publicKey string

// PublicKey returns the embedded Ed25519 public key in normalized form.
func PublicKey() (string, error) { return release.NormalizePublicKey(strings.TrimSpace(publicKey)) }
