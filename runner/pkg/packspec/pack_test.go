package packspec

import (
	"runtime"
	"testing"
)

func TestValidPackID(t *testing.T) {
	cases := []struct {
		id   string
		want bool
	}{
		{"cassandra", true},
		{"linux-core", true},
		{"myorg.cassandra", true},
		{"a.b.c.d", true},
		{"a_b", true},
		{"x1", true},

		{"", false},
		{"-leading-hyphen", false},
		{"_leading-underscore", false},
		{"1leading-digit", false},
		{"trailing.", false},
		{".leading", false},
		{"double..dot", false},
		{"Capital", false},
		{"has space", false},
		{"weird/slash", false},
	}
	for _, c := range cases {
		got := validPackID(c.id)
		if got != c.want {
			t.Errorf("validPackID(%q) = %v, want %v", c.id, got, c.want)
		}
	}
}

func TestPack_Validate(t *testing.T) {
	good := &Pack{
		SchemaVersion: 1,
		ID:            "good",
		Name:          "Good",
		Version:       "0.1.0",
		Description:   "ok",
		Actions:       []string{"actions/a.yaml"},
	}
	if err := good.Validate(); err != nil {
		t.Fatalf("good pack should validate: %v", err)
	}

	cases := []struct {
		name string
		mut  func(*Pack)
	}{
		{"wrong schema", func(p *Pack) { p.SchemaVersion = 2 }},
		{"empty id", func(p *Pack) { p.ID = "" }},
		{"invalid id", func(p *Pack) { p.ID = "Capital" }},
		{"missing name", func(p *Pack) { p.Name = "" }},
		{"missing version", func(p *Pack) { p.Version = "" }},
		{"missing description", func(p *Pack) { p.Description = "" }},
		{"no actions", func(p *Pack) { p.Actions = nil }},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			p := *good
			c.mut(&p)
			if err := p.Validate(); err == nil {
				t.Fatalf("expected validation to fail")
			}
		})
	}
}

func TestRequirements_MatchesHost(t *testing.T) {
	// Empty OS list matches everything.
	if !(Requirements{}).MatchesHost() {
		t.Fatal("empty requirements should match")
	}
	// Current OS is in the list.
	if !(Requirements{OS: []string{runtime.GOOS}}).MatchesHost() {
		t.Fatalf("current OS %s should match", runtime.GOOS)
	}
	// Current OS not in list of one unrelated OS.
	other := "linux"
	if runtime.GOOS == "linux" {
		other = "windows"
	}
	if (Requirements{OS: []string{other}}).MatchesHost() {
		t.Fatalf("other OS %s should not match host %s", other, runtime.GOOS)
	}
	// Mixed list including current OS still matches.
	if !(Requirements{OS: []string{other, runtime.GOOS}}).MatchesHost() {
		t.Fatalf("mixed list including %s should match", runtime.GOOS)
	}
}
