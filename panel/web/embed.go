// Package web holds the embedded frontend (vanilla JS/CSS, no external resources).
package web

import "embed"

// FS contains the static frontend files.
//
//go:embed index.html manifest.webmanifest css js vendor icons
var FS embed.FS
