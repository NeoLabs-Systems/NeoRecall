package cloud

import (
	"fmt"
	"net"
	"net/http"
	"net/url"
	"strings"

	"github.com/NeoLabs-Systems/neorecall/internal/httperr"
)

var blockedCloudHosts = map[string]bool{
	"metadata.google.internal":  true,
	"metadata.google.internal.": true,
}

func isUnspecifiedOrLinkLocalIP(ip net.IP) bool {
	if ip == nil {
		return false
	}
	if ip.IsUnspecified() || ip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast() || ip.IsMulticast() {
		return true
	}
	if v4 := ip.To4(); v4 != nil {
		if v4[0] == 0 || (v4[0] == 169 && v4[1] == 254) || (v4[0] == 255 && v4[1] == 255 && v4[2] == 255 && v4[3] == 255) {
			return true
		}
	}
	return false
}

func isPrivateOrLoopbackHost(host string) bool {
	h := strings.TrimSuffix(strings.ToLower(strings.Trim(host, "[]")), ".")
	if h == "localhost" || strings.HasSuffix(h, ".localhost") || strings.HasSuffix(h, ".local") || strings.HasSuffix(h, ".internal") {
		return true
	}
	ip := net.ParseIP(h)
	if ip == nil {
		return false
	}
	return ip.IsLoopback() || ip.IsPrivate()
}

func isBlockedHost(host string) bool {
	h := strings.TrimSuffix(strings.ToLower(strings.Trim(host, "[]")), ".")
	if blockedCloudHosts[h] || h == "::" || h == "0.0.0.0" || strings.HasPrefix(h, "fe80:") {
		return true
	}
	if ip := net.ParseIP(h); ip != nil && isUnspecifiedOrLinkLocalIP(ip) {
		return true
	}
	return false
}

func invalidURL(msg string) error {
	return httperr.New(http.StatusBadRequest, "INVALID_CLOUD_URL", msg)
}

func NormalizeInstanceURL(raw, label string) (string, error) {
	if label == "" {
		label = "Nextcloud"
	}
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return "", invalidURL(fmt.Sprintf("A %s URL is required.", label))
	}
	parsed, err := url.Parse(trimmed)
	if err != nil {
		return "", invalidURL("That is not a valid URL.")
	}
	if parsed.User != nil {
		return "", invalidURL(fmt.Sprintf("The %s URL must not include credentials.", label))
	}
	if parsed.Scheme != "https" && parsed.Scheme != "http" {
		return "", invalidURL(fmt.Sprintf("The %s URL must be http or https.", label))
	}
	host := parsed.Hostname()
	if host == "" {
		return "", invalidURL(fmt.Sprintf("The %s URL is missing a host.", label))
	}
	if isBlockedHost(host) {
		return "", invalidURL(fmt.Sprintf("That host cannot be used as a %s instance.", label))
	}
	if parsed.Scheme == "http" && !isPrivateOrLoopbackHost(host) {
		return "", invalidURL(fmt.Sprintf("HTTP is only allowed for a local or private %s address. Use HTTPS otherwise.", label))
	}
	if strings.Contains(parsed.Path, "..") {
		return "", invalidURL(fmt.Sprintf("The %s URL path is invalid.", label))
	}
	parsed.Fragment = ""
	parsed.RawQuery = ""
	p := strings.TrimRight(parsed.Path, "/")
	if p == "/" {
		p = ""
	}
	return fmt.Sprintf("%s://%s%s", parsed.Scheme, parsed.Host, p), nil
}

func SameOrigin(left, right string) bool {
	lu, err1 := url.Parse(left)
	ru, err2 := url.Parse(right)
	if err1 != nil || err2 != nil {
		return false
	}
	return strings.EqualFold(lu.Scheme, ru.Scheme) && strings.EqualFold(lu.Host, ru.Host)
}

func JoinURL(base, suffix string) string {
	return strings.TrimRight(base, "/") + "/" + strings.TrimLeft(suffix, "/")
}
