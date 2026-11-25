package timeutil

import (
	"errors"
	"fmt"
	"strings"
	"time"
)

const ISOFormat = "2006-01-02T15:04:05.000Z"

func NowISO() string {
	return FormatISO(time.Now())
}

func FormatISO(t time.Time) string {
	return t.UTC().Format(ISOFormat)
}

func ParseISO(s string) (time.Time, error) {
	s = strings.TrimSpace(s)
	if s == "" {
		return time.Time{}, errors.New("empty timestamp")
	}
	if t, err := time.Parse(time.RFC3339Nano, s); err == nil {
		return t, nil
	}
	return time.Parse(time.RFC3339, s)
}

func AddMillis(t time.Time, ms int64) time.Time {
	return t.Add(time.Duration(ms) * time.Millisecond)
}

func IsIANATimezone(tz string) bool {
	tz = strings.TrimSpace(tz)
	if tz == "" || strings.EqualFold(tz, "local") {
		return false
	}
	_, err := time.LoadLocation(tz)
	return err == nil
}

// LocalDateTimeToUTC resolves YYYY-MM-DDTHH:mm:ss in timezone to ISO-8601 UTC.
func LocalDateTimeToUTC(localDateTime, timezone string) (string, error) {
	loc, err := time.LoadLocation(strings.TrimSpace(timezone))
	if err != nil || loc == nil || strings.EqualFold(timezone, "local") {
		return "", fmt.Errorf("invalid IANA timezone: %s", timezone)
	}
	if len(localDateTime) != 19 {
		return "", errors.New("local date-time must use YYYY-MM-DDTHH:mm:ss without an offset")
	}
	t, err := time.ParseInLocation("2006-01-02T15:04:05", localDateTime, loc)
	if err != nil {
		return "", fmt.Errorf("local date-time is not a valid calendar value: %w", err)
	}
	// Verify round-trip so nonexistent DST gap times are caught cleanly.
	if t.In(loc).Format("2006-01-02T15:04:05") != localDateTime {
		return "", fmt.Errorf("local date-time %s does not exist in %s", localDateTime, timezone)
	}
	return FormatISO(t), nil
}

// LocalDateTimeNow returns YYYY-MM-DDTHH:mm:ss in timezone for t.
func LocalDateTimeNow(timezone string, t time.Time) (string, error) {
	loc, err := time.LoadLocation(strings.TrimSpace(timezone))
	if err != nil || loc == nil || strings.EqualFold(timezone, "local") {
		return "", fmt.Errorf("invalid IANA timezone: %s", timezone)
	}
	return t.In(loc).Format("2006-01-02T15:04:05"), nil
}
