package schema

import (
	"context"

	"github.com/NeoLabs-Systems/neolabs-go/dbx"
	"github.com/NeoLabs-Systems/neolabs-go/dbx/cryptdb"
	"github.com/NeoLabs-Systems/neorecall/internal/config"
	"github.com/NeoLabs-Systems/neorecall/internal/crypto"
)

// Open opens NeoRecall's database, encrypted at rest with a key derived from
// secret.key. A database the Node.js server encrypted is unlocked first, and a
// plaintext one (an earlier Go build, a restored backup) is encrypted.
func Open(ctx context.Context, paths config.Paths, appDir string) (*dbx.DB, error) {
	if _, err := EnsurePlaintextLegacyDB(ctx, paths.Database, paths.SecretKey, appDir, paths.Home); err != nil {
		return nil, err
	}
	key, err := crypto.MasterKey(paths.SecretKey)
	if err != nil {
		return nil, err
	}
	return cryptdb.Open(ctx, paths.Database, key, dbx.Options{})
}
