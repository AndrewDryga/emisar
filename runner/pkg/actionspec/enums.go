// Package actionspec defines the schema for actions — primitive LLM-callable
// capabilities loaded from action packs.
package actionspec

import "fmt"

// Kind is the execution kind of an action.
type Kind string

const (
	KindExec   Kind = "exec"
	KindScript Kind = "script"
)

// Valid reports whether k is a supported action kind.
func (k Kind) Valid() bool {
	switch k {
	case KindExec, KindScript:
		return true
	}
	return false
}

// Risk describes the operational blast radius of an action. Pack authors
// pick the highest value that could plausibly apply.
//
// Ordered: low < medium < high < critical.
type Risk string

const (
	RiskLow      Risk = "low"
	RiskMedium   Risk = "medium"
	RiskHigh     Risk = "high"
	RiskCritical Risk = "critical"
)

var riskRank = map[Risk]int{
	RiskLow:      0,
	RiskMedium:   1,
	RiskHigh:     2,
	RiskCritical: 3,
}

// Valid reports whether r is a supported risk.
func (r Risk) Valid() bool {
	_, ok := riskRank[r]
	return ok
}

// Rank returns the ordinal of r. Higher means more risk. Returns -1 for
// invalid values.
func (r Risk) Rank() int {
	v, ok := riskRank[r]
	if !ok {
		return -1
	}
	return v
}

// LessOrEqual reports whether r's risk is at most other's.
func (r Risk) LessOrEqual(other Risk) bool {
	a, b := r.Rank(), other.Rank()
	return a >= 0 && b >= 0 && a <= b
}

// Parser is the supported stdout parser for actions.
type Parser string

const (
	ParserText Parser = "text"
	ParserJSON Parser = "json"
)

// Valid reports whether p is a supported parser.
func (p Parser) Valid() bool {
	switch p {
	case "", ParserText, ParserJSON:
		return true
	}
	return false
}

// ValidateEnums returns an error if any enum-typed fields on an Action are
// invalid.
func validateEnums(kind Kind, risk Risk, parser Parser) error {
	if !kind.Valid() {
		return fmt.Errorf("invalid kind %q", kind)
	}
	if !risk.Valid() {
		return fmt.Errorf("invalid risk %q", risk)
	}
	if !parser.Valid() {
		return fmt.Errorf("invalid parser %q", parser)
	}
	return nil
}
