package audit

import (
	"context"
	"database/sql"
	"encoding/json"

	"github.com/NeoLabs-Systems/neolabs-go/dbx"
)

type Entry struct {
	ActorType      string
	ActorID        string
	AffectedUserID string
	Action         string
	ResourceType   string
	ResourceID     string
	IPAddress      string
	Metadata       any
}

func nullableStr(s string) sql.NullString {
	if s == "" {
		return sql.NullString{}
	}
	return sql.NullString{String: s, Valid: true}
}

// Record writes one entry into audit_log using DB.W (or an open tx via RecordExec).
func Record(ctx context.Context, db *dbx.DB, e Entry) error {
	return RecordExec(ctx, db.W, e)
}

type Execer interface {
	ExecContext(ctx context.Context, query string, args ...any) (sql.Result, error)
}

func RecordExec(ctx context.Context, ex Execer, e Entry) error {
	var meta sql.NullString
	if e.Metadata != nil {
		raw, err := json.Marshal(e.Metadata)
		if err == nil {
			meta = sql.NullString{String: string(raw), Valid: true}
		}
	}
	_, err := ex.ExecContext(ctx, `INSERT INTO audit_log
		(actor_type, actor_id, affected_user_id, action, resource_type, resource_id, ip_address, metadata_json)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
		e.ActorType,
		nullableStr(e.ActorID),
		nullableStr(e.AffectedUserID),
		e.Action,
		nullableStr(e.ResourceType),
		nullableStr(e.ResourceID),
		nullableStr(e.IPAddress),
		meta,
	)
	return err
}
