package runnerref

import "testing"

func TestBuildAndMatch(t *testing.T) {
	const externalID = "4ce429f6-edde-4dc3-a9b6-89c69e8d8359"
	ref, err := Build("postgres-primary", externalID)
	if err != nil {
		t.Fatalf("Build: %v", err)
	}
	if ref != "postgres-primary~fe0b4e7554f1b421248475e734dc8f7b" {
		t.Fatalf("Build = %q", ref)
	}
	if !Matches(ref, externalID) {
		t.Fatal("built ref did not match its external id")
	}
	if !Matches("renamed~fe0b4e7554f1b421248475e734dc8f7b", externalID) {
		t.Fatal("portal-owned display-name change invalidated the local suffix")
	}
}

func TestMatchesRejectsMalformedOrDifferentGeneration(t *testing.T) {
	const externalID = "runner-generation-a"
	ref, err := Build("db-a", externalID)
	if err != nil {
		t.Fatalf("Build: %v", err)
	}
	for _, candidate := range []string{
		"", "db-a", "~" + ref, "db-a~ABCDEF0123456789ABCDEF0123456789",
		"db-a~0123456789abcdef0123456789abcde", "db-a~0123456789abcdef0123456789abcg",
	} {
		if Matches(candidate, externalID) {
			t.Fatalf("Matches(%q) = true", candidate)
		}
	}
	if Matches(ref, "runner-generation-b") {
		t.Fatal("ref matched a different external-id generation")
	}
}

func TestContainsLocalRequiresExactlyOneMatch(t *testing.T) {
	const externalID = "runner-generation-a"
	first, err := Build("db-a", externalID)
	if err != nil {
		t.Fatalf("Build first: %v", err)
	}
	alias, err := Build("db-renamed", externalID)
	if err != nil {
		t.Fatalf("Build alias: %v", err)
	}
	other, err := Build("db-b", "runner-generation-b")
	if err != nil {
		t.Fatalf("Build other: %v", err)
	}

	if !ContainsLocal([]string{other, first}, externalID) {
		t.Fatal("one matching ref was rejected")
	}
	if ContainsLocal([]string{other}, externalID) {
		t.Fatal("missing local ref was accepted")
	}
	if ContainsLocal([]string{first, alias}, externalID) {
		t.Fatal("two aliases for one local generation were accepted")
	}
}

func TestBuildRejectsInvalidInputs(t *testing.T) {
	for _, tc := range []struct {
		name       string
		externalID string
	}{
		{"", "runner"},
		{"bad~name", "runner"},
		{"runner", ""},
	} {
		if _, err := Build(tc.name, tc.externalID); err == nil {
			t.Fatalf("Build(%q, %q) unexpectedly succeeded", tc.name, tc.externalID)
		}
	}
}
