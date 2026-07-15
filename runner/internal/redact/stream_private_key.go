package redact

import "bytes"

const (
	privateKeyBeginPrefix  = "-----BEGIN "
	privateKeyMarkerSuffix = "-----"
	maxPrivateKeyLabel     = 64
)

type privateKeyStreamRule struct {
	enabled     bool
	name        string
	replacement []byte
}

// privateKeyStreamMasker handles the two default delimiter-based secret rules
// without buffering their bodies. Generic regex rules remain bounded by the
// StreamRedactor hold window; private keys are masked through END or EOF.
type privateKeyStreamMasker struct {
	generic privateKeyStreamRule
	pgp     privateKeyStreamRule

	pending []byte
	end     []byte
	active  bool
	hits    []Hit
}

func newPrivateKeyStreamMasker(e *Engine) privateKeyStreamMasker {
	var masker privateKeyStreamMasker
	if e == nil {
		return masker
	}
	for _, rule := range e.rules {
		if rule.regex == nil {
			continue
		}
		streamRule := privateKeyStreamRule{
			enabled:     true,
			name:        rule.Name,
			replacement: []byte(rule.Replacement),
		}
		switch rule.regex.String() {
		case privateKeyBlockPattern:
			if !masker.generic.enabled {
				masker.generic = streamRule
			}
		case pgpPrivateKeyBlockPattern:
			if !masker.pgp.enabled {
				masker.pgp = streamRule
			}
		}
	}
	return masker
}

func (m *privateKeyStreamMasker) Write(p []byte) []byte {
	if !m.generic.enabled && !m.pgp.enabled {
		return p
	}
	m.pending = append(m.pending, p...)
	return m.commit(false)
}

func (m *privateKeyStreamMasker) Flush() []byte {
	if !m.generic.enabled && !m.pgp.enabled {
		return nil
	}
	return m.commit(true)
}

func (m *privateKeyStreamMasker) Hits() []Hit { return m.hits }

func (m *privateKeyStreamMasker) commit(flush bool) []byte {
	var out []byte
	for {
		if m.active {
			endAt := bytes.Index(m.pending, m.end)
			if endAt >= 0 {
				m.pending = m.pending[endAt+len(m.end):]
				m.active = false
				m.end = nil
				continue
			}
			if flush {
				m.pending = nil
				return out
			}
			keep := len(m.end) - 1
			if len(m.pending) > keep {
				m.pending = append([]byte(nil), m.pending[len(m.pending)-keep:]...)
			}
			return out
		}

		beginAt := bytes.Index(m.pending, []byte(privateKeyBeginPrefix))
		if beginAt < 0 {
			keep := len(privateKeyBeginPrefix) - 1
			if flush {
				keep = 0
			}
			emit := len(m.pending) - keep
			if emit <= 0 {
				return out
			}
			out = append(out, m.pending[:emit]...)
			m.pending = append([]byte(nil), m.pending[emit:]...)
			return out
		}

		out = append(out, m.pending[:beginAt]...)
		m.pending = m.pending[beginAt:]
		labelStart := len(privateKeyBeginPrefix)
		markerAt := bytes.Index(m.pending[labelStart:], []byte(privateKeyMarkerSuffix))
		if markerAt < 0 {
			label := m.pending[labelStart:]
			if len(label) <= maxPrivateKeyLabel && validPrivateKeyLabelFragment(label) && !flush {
				return out
			}
			out = append(out, m.pending[0])
			m.pending = m.pending[1:]
			continue
		}

		labelEnd := labelStart + markerAt
		label := m.pending[labelStart:labelEnd]
		rule, ok := m.ruleForLabel(label)
		if !ok {
			out = append(out, m.pending[0])
			m.pending = m.pending[1:]
			continue
		}

		out = append(out, rule.replacement...)
		m.hits = MergeHits(m.hits, []Hit{{Name: rule.name, Type: "regex", Count: 1}})
		m.end = []byte("-----END " + string(label) + "-----")
		m.active = true
		m.pending = m.pending[labelEnd+len(privateKeyMarkerSuffix):]
	}
}

func (m *privateKeyStreamMasker) ruleForLabel(label []byte) (privateKeyStreamRule, bool) {
	if len(label) == 0 || len(label) > maxPrivateKeyLabel {
		return privateKeyStreamRule{}, false
	}
	if bytes.Equal(label, []byte("PGP PRIVATE KEY BLOCK")) {
		return m.pgp, m.pgp.enabled
	}
	if !bytes.HasSuffix(label, []byte("PRIVATE KEY")) || !validPrivateKeyLabelFragment(label) {
		return privateKeyStreamRule{}, false
	}
	return m.generic, m.generic.enabled
}

func validPrivateKeyLabelFragment(label []byte) bool {
	for _, b := range label {
		if b != ' ' && (b < 'A' || b > 'Z') {
			return false
		}
	}
	return true
}
