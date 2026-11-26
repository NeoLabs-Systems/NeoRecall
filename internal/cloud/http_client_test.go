package cloud

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// The cloud client reaches a server on the user's own network without becoming
// a way into link-local addresses or a redirect to somewhere else.
func TestInstanceClientReach(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "http://169.254.169.254/latest/meta-data", http.StatusFound)
	}))
	defer srv.Close()
	client := (&Service{}).httpClient()

	res, err := client.Get(srv.URL)
	if err != nil {
		t.Fatalf("loopback instance refused: %v", err)
	}
	res.Body.Close()
	if res.StatusCode != http.StatusFound {
		t.Fatalf("redirect was followed: %d", res.StatusCode)
	}
	for _, address := range []string{"http://169.254.169.254/", "http://0.0.0.0:1/", "http://[fe80::1]:1/"} {
		if _, err := client.Get(address); err == nil || !strings.Contains(err.Error(), "not an allowed destination") {
			t.Fatalf("%s: %v", address, err)
		}
	}
}
