package context

import (
	"archive/zip"
	"bytes"
	"compress/zlib"
	"encoding/xml"
	"io"
	"net/http"
	"path/filepath"
	"regexp"
	"strings"
	"unicode/utf8"
)

var (
	streamRe = regexp.MustCompile(`(?s)stream\r?\n(.*?)\r?\n?endstream`)
	btEtRe   = regexp.MustCompile(`(?s)BT\b(.*?)\bET\b`)
	textOpRe = regexp.MustCompile(`\(((?:\\.|[^\\()])*)\)\s*Tj|\[((?:[^\[\]]|\((?:\\.|[^\\()])*\))*)\]\s*TJ`)
	parenRe  = regexp.MustCompile(`\(((?:\\.|[^\\()])*)\)`)
)

type ClassifiedUpload struct {
	Kind        string // "image", "document", "file"
	ContentType string
	Extracted   string
}

func ClassifyAndExtract(filename, declaredCT string, data []byte, maxExtractChars int) ClassifiedUpload {
	ext := strings.ToLower(filepath.Ext(filename))
	ct := strings.ToLower(strings.TrimSpace(strings.Split(declaredCT, ";")[0]))
	sniffed := strings.ToLower(http.DetectContentType(data))

	// Image sniffing by magic header
	switch {
	case bytes.HasPrefix(data, []byte{0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'}):
		return ClassifiedUpload{Kind: "image", ContentType: "image/png"}
	case len(data) >= 3 && data[0] == 0xff && data[1] == 0xd8 && data[2] == 0xff:
		return ClassifiedUpload{Kind: "image", ContentType: "image/jpeg"}
	case len(data) >= 12 && string(data[:4]) == "RIFF" && string(data[8:12]) == "WEBP":
		return ClassifiedUpload{Kind: "image", ContentType: "image/webp"}
	case bytes.HasPrefix(data, []byte("GIF87a")) || bytes.HasPrefix(data, []byte("GIF89a")):
		return ClassifiedUpload{Kind: "image", ContentType: "image/gif"}
	}

	// PDF
	if bytes.HasPrefix(data, []byte("%PDF-")) || ext == ".pdf" || ct == "application/pdf" {
		txt := extractPDFText(data, maxExtractChars)
		return ClassifiedUpload{Kind: "document", ContentType: "application/pdf", Extracted: txt}
	}

	// DOCX (ZIP with word/document.xml)
	if bytes.HasPrefix(data, []byte{'P', 'K', 0x03, 0x04}) &&
		(ext == ".docx" || ct == "application/vnd.openxmlformats-officedocument.wordprocessingml.document") {
		txt := extractDOCXText(data, maxExtractChars)
		return ClassifiedUpload{
			Kind:        "document",
			ContentType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
			Extracted:   txt,
		}
	}

	// Plain UTF-8 text-based formats
	textExts := map[string]string{
		".txt":      "text/plain",
		".md":       "text/markdown",
		".markdown": "text/markdown",
		".csv":      "text/csv",
		".json":     "application/json",
		".yaml":     "text/yaml",
		".yml":      "text/yaml",
		".log":      "text/plain",
	}
	if _, ok := textExts[ext]; ok || strings.HasPrefix(ct, "text/") || ct == "application/json" || strings.HasPrefix(sniffed, "text/") {
		if utf8.Valid(data) && !bytes.ContainsRune(data, 0) {
			txt := boundString(strings.TrimSpace(string(data)), maxExtractChars)
			outCT := ct
			if outCT == "" {
				if c, ok := textExts[ext]; ok {
					outCT = c
				} else {
					outCT = "text/plain"
				}
			}
			kind := "file"
			if ext == ".txt" || ext == ".md" || ext == ".markdown" || ext == ".csv" || ext == ".json" {
				kind = "document"
			}
			return ClassifiedUpload{Kind: kind, ContentType: outCT, Extracted: txt}
		}
	}

	if ct == "" {
		ct = "application/octet-stream"
	}
	return ClassifiedUpload{Kind: "file", ContentType: ct}
}

func boundString(s string, maxChars int) string {
	if maxChars <= 0 {
		return s
	}
	r := []rune(s)
	if len(r) <= maxChars {
		return s
	}
	return string(r[:maxChars])
}

func extractDOCXText(data []byte, maxChars int) string {
	zr, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		return ""
	}
	for _, f := range zr.File {
		if f.Name != "word/document.xml" {
			continue
		}
		rc, err := f.Open()
		if err != nil {
			return ""
		}
		xmlBytes, _ := io.ReadAll(io.LimitReader(rc, 8<<20))
		rc.Close()
		dec := xml.NewDecoder(bytes.NewReader(xmlBytes))
		var sb strings.Builder
		var inText bool
		for {
			tok, err := dec.Token()
			if err != nil {
				break
			}
			switch el := tok.(type) {
			case xml.StartElement:
				if el.Name.Local == "t" {
					inText = true
				} else if el.Name.Local == "tab" {
					sb.WriteByte('\t')
				} else if el.Name.Local == "br" {
					sb.WriteByte('\n')
				}
			case xml.EndElement:
				if el.Name.Local == "t" {
					inText = false
				} else if el.Name.Local == "p" {
					sb.WriteByte('\n')
				}
			case xml.CharData:
				if inText {
					sb.Write(el)
				}
			}
			if maxChars > 0 && sb.Len() >= maxChars*4 {
				break
			}
		}
		return boundString(strings.TrimSpace(sb.String()), maxChars)
	}
	return ""
}

func extractPDFText(data []byte, maxChars int) string {
	if len(data) > 32<<20 {
		data = data[:32<<20]
	}
	var sb strings.Builder
	extractFromContent := func(src []byte) {
		blocks := btEtRe.FindAllSubmatch(src, -1)
		if len(blocks) == 0 {
			return
		}
		for _, blk := range blocks {
			for _, m := range textOpRe.FindAllSubmatch(blk[1], -1) {
				if len(m[1]) > 0 {
					sb.WriteString(unescapePDFString(string(m[1])))
					sb.WriteByte(' ')
				} else if len(m[2]) > 0 {
					for _, pm := range parenRe.FindAllSubmatch(m[2], -1) {
						sb.WriteString(unescapePDFString(string(pm[1])))
					}
					sb.WriteByte(' ')
				}
			}
			sb.WriteByte('\n')
			if maxChars > 0 && sb.Len() >= maxChars*4 {
				return
			}
		}
	}

	streams := streamRe.FindAllSubmatch(data, -1)
	if len(streams) == 0 {
		extractFromContent(data)
		return boundString(strings.TrimSpace(sb.String()), maxChars)
	}
	for _, sm := range streams {
		raw := sm[1]
		if zr, err := zlib.NewReader(bytes.NewReader(raw)); err == nil {
			dec, _ := io.ReadAll(io.LimitReader(zr, 4<<20))
			_ = zr.Close()
			if len(dec) > 0 {
				extractFromContent(dec)
			}
		} else {
			extractFromContent(raw)
		}
		if maxChars > 0 && sb.Len() >= maxChars*4 {
			break
		}
	}
	return boundString(strings.TrimSpace(sb.String()), maxChars)
}

func unescapePDFString(s string) string {
	var sb strings.Builder
	for i := 0; i < len(s); i++ {
		if s[i] == '\\' && i+1 < len(s) {
			i++
			switch s[i] {
			case 'n':
				sb.WriteByte('\n')
			case 'r':
				sb.WriteByte('\r')
			case 't':
				sb.WriteByte('\t')
			case '(', ')', '\\':
				sb.WriteByte(s[i])
			default:
				sb.WriteByte(s[i])
			}
			continue
		}
		if s[i] >= 0x20 || s[i] == '\n' || s[i] == '\t' {
			sb.WriteByte(s[i])
		}
	}
	return sb.String()
}
