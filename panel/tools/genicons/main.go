//go:build ignore

// genicons renders the PWA / favicon PNGs into web/icons (run once, output is committed):
//
//	go run ./tools/genicons web/icons
package main

import (
	"image"
	"image/color"
	"image/png"
	"math"
	"os"
	"path/filepath"
)

type rgba struct{ r, g, b, a float64 }

func main() {
	out := "web/icons"
	if len(os.Args) > 1 {
		out = os.Args[1]
	}
	must(os.MkdirAll(out, 0o755))
	for _, s := range []struct {
		name     string
		size     int
		maskable bool
	}{
		{"icon-512.png", 512, false},
		{"icon-192.png", 192, false},
		{"maskable-512.png", 512, true},
		{"maskable-192.png", 192, true},
		{"apple-touch-icon.png", 180, true},
		{"favicon-32.png", 32, false},
	} {
		img := render(s.size, s.maskable)
		f, err := os.Create(filepath.Join(out, s.name))
		must(err)
		must((&png.Encoder{CompressionLevel: png.BestCompression}).Encode(f, img))
		must(f.Close())
	}
}

func must(err error) {
	if err != nil {
		panic(err)
	}
}

// render draws the icon in unit space [0,1]² with 4×4 supersampling.
func render(size int, maskable bool) *image.NRGBA {
	img := image.NewNRGBA(image.Rect(0, 0, size, size))
	const ss = 4
	top := rgba{0.16, 0.47, 0.90, 1}    // #2978e6
	bottom := rgba{0.05, 0.25, 0.60, 1} // #0d4099
	dark := rgba{0.05, 0.25, 0.60, 1}
	white := rgba{1, 1, 1, 1}
	// House geometry (unit space), scaled around the centre for maskable icons.
	scale := 1.0
	if maskable {
		scale = 0.78
	}
	tr := func(x, y float64) (float64, float64) { return 0.5 + (x-0.5)/scale, 0.5 + (y-0.5)/scale }
	for py := 0; py < size; py++ {
		for px := 0; px < size; px++ {
			var acc rgba
			for sy := 0; sy < ss; sy++ {
				for sx := 0; sx < ss; sx++ {
					x := (float64(px) + (float64(sx)+0.5)/ss) / float64(size)
					y := (float64(py) + (float64(sy)+0.5)/ss) / float64(size)
					var c rgba
					inBg := maskable || roundedRect(x, y, 0, 0, 1, 1, 0.22)
					if inBg {
						c = lerp(top, bottom, y)
					}
					hx, hy := tr(x, y)
					if house(hx, hy) {
						c = white
						if keyhole(hx, hy) {
							c = dark
						}
					}
					acc.r += c.r * c.a
					acc.g += c.g * c.a
					acc.b += c.b * c.a
					acc.a += c.a
				}
			}
			n := float64(ss * ss)
			a := acc.a / n
			var col color.NRGBA
			if a > 0 {
				col = color.NRGBA{
					R: uint8(math.Round(acc.r / acc.a * 255)),
					G: uint8(math.Round(acc.g / acc.a * 255)),
					B: uint8(math.Round(acc.b / acc.a * 255)),
					A: uint8(math.Round(a * 255)),
				}
			}
			img.SetNRGBA(px, py, col)
		}
	}
	return img
}

func lerp(a, b rgba, t float64) rgba {
	return rgba{a.r + (b.r-a.r)*t, a.g + (b.g-a.g)*t, a.b + (b.b-a.b)*t, 1}
}

func roundedRect(x, y, x0, y0, x1, y1, r float64) bool {
	if x < x0 || x > x1 || y < y0 || y > y1 {
		return false
	}
	cx := math.Max(x0+r, math.Min(x, x1-r))
	cy := math.Max(y0+r, math.Min(y, y1-r))
	return (x-cx)*(x-cx)+(y-cy)*(y-cy) <= r*r
}

// house = roof triangle + body rectangle (a simple vault-like home silhouette).
func house(x, y float64) bool {
	// roof: apex (0.5,0.20), base (0.17,0.47)–(0.83,0.47)
	if y >= 0.20 && y <= 0.47 {
		half := (y - 0.20) / 0.27 * 0.33
		if math.Abs(x-0.5) <= half {
			return true
		}
	}
	// chimney
	if x >= 0.66 && x <= 0.74 && y >= 0.24 && y <= 0.40 {
		return true
	}
	// body
	return roundedRect(x, y, 0.25, 0.45, 0.75, 0.80, 0.03)
}

// keyhole = circle + tapered slot.
func keyhole(x, y float64) bool {
	if (x-0.5)*(x-0.5)+(y-0.58)*(y-0.58) <= 0.055*0.055 {
		return true
	}
	if y >= 0.58 && y <= 0.72 {
		half := 0.022 + (y-0.58)/0.14*0.02
		return math.Abs(x-0.5) <= half
	}
	return false
}
