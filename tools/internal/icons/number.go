package icons

import (
	"math"
	"math/big"
	"strconv"
)

// The icon masters were normalized by JavaScript, and the committed SVGs are
// its output. Every number that reaches a file goes through these helpers so
// the Go tooling reproduces those bytes exactly: JavaScript rounds ties toward
// +∞ (Math.round(-2.5) is -2), prints the shortest decimal that round-trips,
// and never prints a negative zero. Go's math.Round and %v disagree on all
// three, and a one-character drift here rewrites the entire icon set.

// jsRound is Math.round: the nearest integer, ties toward +∞, computed without
// the x+0.5 overflow that misrounds 0.49999999999999994.
func jsRound(x float64) float64 {
	floor := math.Floor(x)
	if x-floor >= 0.5 {
		floor++
	}
	if floor == 0 {
		return 0 // +0, never the -0 Math.floor yields for (-0.5, 0]
	}
	return floor
}

// halfGrid snaps to .0/.5, quarterGrid to .0/.25/.5/.75.
func halfGrid(v float64) float64    { return jsRound(v*2) / 2 }
func quarterGrid(v float64) float64 { return jsRound(v*4) / 4 }

// pixelCentre snaps the centre line of a 1px axis-aligned run to the nearest
// n+0.5, where both stroke edges land on device-pixel boundaries at 1x, 2x and
// 3x; an integer centre splits the run across two pixel rows at 1x. A value
// within rounding of an integer is a tie, and a tie breaks away from the centre
// so a symmetric pair of edges grows together instead of shifting. (The centre
// is 8, or 7.5 once the drawing has moved; an integer lies on the same side of
// both.) The box centre is no exception: a run on it never gets here, because
// the cutter moves the whole drawing off it first (mirrorShift).
func pixelCentre(v float64) float64 {
	if r := jsRound(v); math.Abs(v-r) < 0.02 {
		if v < 8 {
			return r - 0.5
		}
		return r + 0.5
	}
	return math.Floor(v) + 0.5
}

// format is String(Math.round(v * 100) / 100): two decimals at most, printed the
// shortest way that round-trips. The explicit float64 conversion keeps the
// multiply from fusing into the comparison inside jsRound on arm64.
func format(v float64) string {
	return jsString(jsRound(float64(v*100)) / 100)
}

// jsString is Number#toString for the magnitudes an icon grid produces.
func jsString(v float64) string {
	if v == 0 {
		return "0"
	}
	return strconv.FormatFloat(v, 'f', -1, 64)
}

// toFixed is +x.toFixed(digits): decimal rounding of the exact binary value with
// ties rounded away from zero, then the nearest float64 of that decimal.
// strconv rounds an exact tie to even, so 0.125 would print as 0.12 where
// JavaScript prints 0.13 — and quarter-grid geometry lands on eighths often.
func toFixed(x float64, digits int) float64 {
	negative := x < 0
	if negative {
		x = -x
	}
	scale := new(big.Int).Exp(big.NewInt(10), big.NewInt(int64(digits)), nil)
	exact := new(big.Rat).SetFloat64(x)
	exact.Mul(exact, new(big.Rat).SetInt(scale))
	whole := new(big.Int).Quo(exact.Num(), exact.Denom())
	fraction := new(big.Rat).Sub(exact, new(big.Rat).SetInt(whole))
	if fraction.Cmp(big.NewRat(1, 2)) >= 0 {
		whole.Add(whole, big.NewInt(1))
	}
	rounded, _ := new(big.Rat).SetFrac(whole, scale).Float64()
	if negative {
		rounded = -rounded
	}
	if rounded == 0 {
		return 0
	}
	return rounded
}
