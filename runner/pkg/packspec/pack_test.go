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
		{"non-numeric retired_below", func(p *Pack) { p.RetiredBelow = "1.2.x" }},
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

func TestSetup_Validate(t *testing.T) {
	good := Setup{
		Env: []EnvVar{{Name: "PGHOST", Required: true}, {Name: "PGPORT"}},
		HostAccess: []HostAccess{{
			Actions:     []string{"p.status", "p.logs"},
			Requirement: "Read the service log.",
			Recipes: []HostAccessRecipe{{
				Name:     "systemd",
				Commands: []string{"sudo install -m 0640 file /etc/service.conf"},
				Verify:   []string{"sudo -u emisar test -r /etc/service.conf"},
				Impact:   "Lets the runner read this service configuration.",
			}},
		}},
	}
	if err := good.Validate("p"); err != nil {
		t.Fatalf("good setup should validate: %v", err)
	}
	if err := (Setup{}).Validate("p"); err != nil {
		t.Fatalf("empty setup should validate: %v", err)
	}

	bad := []struct {
		name  string
		setup Setup
	}{
		{"empty env name", Setup{Env: []EnvVar{{Name: ""}}}},
		{"hyphen in name", Setup{Env: []EnvVar{{Name: "HAS-DASH"}}}},
		{"leading digit", Setup{Env: []EnvVar{{Name: "1ABC"}}}},
		{"space in name", Setup{Env: []EnvVar{{Name: "A B"}}}},
		{"duplicate var", Setup{Env: []EnvVar{{Name: "X"}, {Name: "X"}}}},
		{"missing actions", setupWithHostAccess(func(access *HostAccess) { access.Actions = nil })},
		{"duplicate action", setupWithHostAccess(func(access *HostAccess) { access.Actions = []string{"p.status", "p.status"} })},
		{"missing requirement", setupWithHostAccess(func(access *HostAccess) { access.Requirement = " " })},
		{"missing recipes", setupWithHostAccess(func(access *HostAccess) { access.Recipes = nil })},
		{"missing recipe name", setupWithHostAccess(func(access *HostAccess) { access.Recipes[0].Name = "" })},
		{"duplicate recipe name", setupWithHostAccess(func(access *HostAccess) { access.Recipes = append(access.Recipes, access.Recipes[0]) })},
		{"normalized duplicate recipe name", setupWithHostAccess(func(access *HostAccess) {
			copy := access.Recipes[0]
			copy.Name = "systemd\n"
			access.Recipes = append(access.Recipes, copy)
		})},
		{"missing commands", setupWithHostAccess(func(access *HostAccess) { access.Recipes[0].Commands = nil })},
		{"missing verify", setupWithHostAccess(func(access *HostAccess) { access.Recipes[0].Verify = nil })},
		{"missing impact", setupWithHostAccess(func(access *HostAccess) { access.Recipes[0].Impact = "" })},
		{"escape in command", setupWithHostAccess(func(access *HostAccess) { access.Recipes[0].Commands[0] = "echo\x1b[2J" })},
		{"newline in command", setupWithHostAccess(func(access *HostAccess) { access.Recipes[0].Commands[0] = "echo ok\necho hidden" })},
		{"bidi override", setupWithHostAccess(func(access *HostAccess) { access.Recipes[0].Impact = "safe\u202eevil" })},
		{"zero width format control", setupWithHostAccess(func(access *HostAccess) { access.Recipes[0].Impact = "safe\u200bevil" })},
		{"invalid utf8", setupWithHostAccess(func(access *HostAccess) { access.Recipes[0].Name = string([]byte{0xff}) })},
	}
	for _, c := range bad {
		t.Run(c.name, func(t *testing.T) {
			if err := c.setup.Validate("p"); err == nil {
				t.Fatalf("expected validation to fail")
			}
		})
	}
}

func setupWithHostAccess(mutate func(*HostAccess)) Setup {
	access := HostAccess{
		Actions:     []string{"p.status"},
		Requirement: "Reach the service socket.",
		Recipes: []HostAccessRecipe{{
			Name:     "systemd",
			Commands: []string{"sudo systemctl edit service"},
			Verify:   []string{"sudo -u emisar test -r /run/service.sock"},
			Impact:   "Lets the runner control the service.",
		}},
	}
	mutate(&access)
	return Setup{HostAccess: []HostAccess{access}}
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
