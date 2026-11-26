package cloud

import (
	"fmt"
	"net"
	"net/http"
	"syscall"
	"time"
)

// newInstanceClient reaches the server the user typed in, which is often on the
// same machine or LAN. Link-local (including cloud metadata), unspecified and
// multicast addresses stay refused after DNS resolution, and redirects are never
// followed so an instance cannot point NeoRecall elsewhere.
func newInstanceClient() *http.Client {
	dialer := &net.Dialer{
		Timeout: 10 * time.Second,
		Control: func(_, address string, _ syscall.RawConn) error {
			host, _, err := net.SplitHostPort(address)
			if err != nil {
				return err
			}
			if ip := net.ParseIP(host); ip == nil || isUnspecifiedOrLinkLocalIP(ip) {
				return fmt.Errorf("cloud: %s is not an allowed destination", host)
			}
			return nil
		},
	}
	// No client-wide timeout: requests carry their own deadlines, and uploads
	// of long recordings outlast any fixed one.
	return &http.Client{
		Transport:     &http.Transport{DialContext: dialer.DialContext, TLSHandshakeTimeout: 10 * time.Second},
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
}
