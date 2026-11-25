package signing

import "testing"

func TestPublicKey(t *testing.T) {
	if _, err := PublicKey(); err != nil {
		t.Fatal(err)
	}
}
