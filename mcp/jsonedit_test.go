package main

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestInsertJSONMemberPreservesDocument(t *testing.T) {
	cases := []struct {
		name      string
		raw       string
		path      []string
		preserved []string
	}{
		{
			name: "empty file",
			raw:  "",
			path: []string{"mcpServers"},
		},
		{
			name:      "existing container keeps sibling order",
			raw:       "{\n  \"zeta\": 1,\n  \"mcpServers\": {\n    \"other\": {\"command\": \"x\"}\n  },\n  \"alpha\": 2\n}\n",
			path:      []string{"mcpServers"},
			preserved: []string{"\"zeta\": 1", "\"other\"", "\"alpha\": 2"},
		},
		{
			name:      "missing container is created",
			raw:       "{\n  \"editor\": {\"theme\": \"dark\"}\n}\n",
			path:      []string{"mcpServers"},
			preserved: []string{"\"theme\": \"dark\""},
		},
		{
			name:      "nested container is created",
			raw:       "{\n  \"unrelated\": true\n}\n",
			path:      []string{"mcp", "servers"},
			preserved: []string{"\"unrelated\": true"},
		},
		{
			name:      "nested container is reused",
			raw:       "{\n  \"mcp\": {\n    \"servers\": {},\n    \"timeout\": 5\n  }\n}\n",
			path:      []string{"mcp", "servers"},
			preserved: []string{"\"timeout\": 5"},
		},
		{
			name:      "line comments survive",
			raw:       "{\n  // keep me\n  \"servers\": {\n    // and me\n  }\n}\n",
			path:      []string{"servers"},
			preserved: []string{"// keep me", "// and me"},
		},
		{
			name:      "block comments and trailing commas survive",
			raw:       "{\n  /* header */\n  \"context_servers\": {\n    \"other\": {\"source\": \"custom\"},\n  },\n}\n",
			path:      []string{"context_servers"},
			preserved: []string{"/* header */", "\"other\""},
		},
	}

	entry := stdServerEntry{Command: "/usr/local/bin/emisar-mcp", Env: clientEnvBlock{
		URL: "https://emisar.dev", APIKey: "emk-key", Client: "cursor",
	}}

	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			edited, err := insertJSONMember(testCase.raw, testCase.path, emisarServerName, entry)
			if err != nil {
				t.Fatalf("insertJSONMember: %v", err)
			}
			for _, fragment := range testCase.preserved {
				if !strings.Contains(edited, fragment) {
					t.Errorf("edit dropped %q:\n%s", fragment, edited)
				}
			}
			document, err := parseJSONConfig(edited)
			if err != nil {
				t.Fatalf("edited document does not parse: %v\n%s", err, edited)
			}
			written, ok := lookupJSONPath(document, testCase.path, emisarServerName)
			if !ok {
				t.Fatalf("emisar entry missing after insert:\n%s", edited)
			}
			if !sameJSONValue(written, entry) {
				t.Errorf("entry mismatch: %#v", written)
			}
		})
	}
}

func TestInsertJSONMemberReplacesExistingEntry(t *testing.T) {
	raw := "{\n  \"mcpServers\": {\n    \"emisar\": {\"command\": \"stale\"},\n    \"other\": {\"command\": \"keep\"}\n  }\n}\n"
	entry := stdServerEntry{Command: "fresh", Env: clientEnvBlock{URL: "https://emisar.dev", APIKey: "emk-key", Client: "cursor"}}
	edited, err := insertJSONMember(raw, []string{"mcpServers"}, emisarServerName, entry)
	if err != nil {
		t.Fatalf("insertJSONMember: %v", err)
	}
	if strings.Contains(edited, "stale") {
		t.Errorf("stale entry survived:\n%s", edited)
	}
	if !strings.Contains(edited, "\"other\"") {
		t.Errorf("sibling dropped:\n%s", edited)
	}
	document, err := parseJSONConfig(edited)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	written, _ := lookupJSONPath(document, []string{"mcpServers"}, emisarServerName)
	if !sameJSONValue(written, entry) {
		t.Errorf("entry not replaced: %#v", written)
	}
}

func TestRemoveJSONMemberLeavesValidJSON(t *testing.T) {
	cases := []struct {
		name string
		raw  string
	}{
		{
			name: "only member",
			raw:  "{\n  \"mcpServers\": {\n    \"emisar\": {\"command\": \"x\"}\n  }\n}\n",
		},
		{
			name: "first member",
			raw:  "{\n  \"mcpServers\": {\n    \"emisar\": {\"command\": \"x\"},\n    \"other\": {\"command\": \"y\"}\n  }\n}\n",
		},
		{
			name: "last member",
			raw:  "{\n  \"mcpServers\": {\n    \"other\": {\"command\": \"y\"},\n    \"emisar\": {\"command\": \"x\"}\n  }\n}\n",
		},
		{
			name: "middle member",
			raw:  "{\n  \"mcpServers\": {\n    \"a\": 1,\n    \"emisar\": {\"command\": \"x\"},\n    \"b\": 2\n  }\n}\n",
		},
		{
			name: "commented document",
			raw:  "{\n  // keep\n  \"mcpServers\": {\n    \"emisar\": {\"command\": \"x\"},\n    \"other\": {\"command\": \"y\"}\n  }\n}\n",
		},
	}

	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			edited, removed, err := removeJSONMember(testCase.raw, []string{"mcpServers"}, emisarServerName)
			if err != nil {
				t.Fatalf("removeJSONMember: %v", err)
			}
			if !removed {
				t.Fatal("expected a removal")
			}
			if strings.Contains(edited, "\"emisar\"") {
				t.Errorf("entry survived:\n%s", edited)
			}
			if strings.Contains(testCase.raw, "\"other\"") && !strings.Contains(edited, "\"other\"") {
				t.Errorf("sibling dropped:\n%s", edited)
			}
			// The document must parse STRICTLY when it carried no comments: a
			// dangling separator comma is legal JSONC but breaks a plain JSON
			// client such as Claude Code.
			if !strings.Contains(testCase.raw, "//") {
				var document map[string]any
				if err := json.Unmarshal([]byte(edited), &document); err != nil {
					t.Fatalf("edited document is not strict JSON: %v\n%s", err, edited)
				}
			}
			if _, err := parseJSONConfig(edited); err != nil {
				t.Fatalf("edited document does not parse: %v\n%s", err, edited)
			}
		})
	}
}

func TestRemoveJSONMemberAbsentIsNoChange(t *testing.T) {
	raw := "{\n  \"mcpServers\": {\n    \"other\": {}\n  }\n}\n"
	edited, removed, err := removeJSONMember(raw, []string{"mcpServers"}, emisarServerName)
	if err != nil {
		t.Fatalf("removeJSONMember: %v", err)
	}
	if removed || edited != raw {
		t.Errorf("expected no change, got removed=%v:\n%s", removed, edited)
	}
}

func TestInsertJSONMemberRejectsNonObjectRoot(t *testing.T) {
	for _, raw := range []string{"[]\n", "\"text\"\n", "42\n"} {
		if _, err := insertJSONMember(raw, []string{"mcpServers"}, emisarServerName, stdServerEntry{}); err == nil {
			t.Errorf("expected a refusal for %q", raw)
		}
	}
}

func TestInsertJSONMemberRejectsNonObjectContainer(t *testing.T) {
	raw := "{\n  \"mcpServers\": \"not an object\"\n}\n"
	if _, err := insertJSONMember(raw, []string{"mcpServers"}, emisarServerName, stdServerEntry{}); err == nil {
		t.Error("expected a refusal when the container is not an object")
	}
}

func TestStripJSONCKeepsStringContent(t *testing.T) {
	raw := "{\n  \"url\": \"https://emisar.dev/a//b\", // trailing\n  \"note\": \"/* not a comment */\",\n}\n"
	var document map[string]any
	if err := json.Unmarshal([]byte(stripJSONC(raw)), &document); err != nil {
		t.Fatalf("stripJSONC output does not parse: %v", err)
	}
	if document["url"] != "https://emisar.dev/a//b" {
		t.Errorf("url was rewritten: %v", document["url"])
	}
	if document["note"] != "/* not a comment */" {
		t.Errorf("note was rewritten: %v", document["note"])
	}
}

// A config we create is a file the operator will open and read, so an empty
// object must not leave its closing brace stranded on the member's line.
func TestInsertJSONMemberFormatsAnEmptyObject(t *testing.T) {
	cases := map[string]string{
		"":                             "{\n  \"mcpServers\": {\n",
		"{}\n":                         "{\n  \"mcpServers\": {\n",
		"{\n  \"mcpServers\": {}\n}\n": "\n  }\n}\n",
	}
	entry := stdServerEntry{Command: "/usr/local/bin/emisar-mcp"}
	for raw, want := range cases {
		edited, err := insertJSONMember(raw, []string{"mcpServers"}, emisarServerName, entry)
		if err != nil {
			t.Fatalf("insertJSONMember(%q): %v", raw, err)
		}
		if !strings.Contains(edited, want) {
			t.Errorf("insertJSONMember(%q) = %q, want it to contain %q", raw, edited, want)
		}
		if strings.Contains(edited, "}}") {
			t.Errorf("insertJSONMember(%q) left a stranded brace:\n%s", raw, edited)
		}
	}
}

// VS Code and Cursor load a config whose only JSONC spelling is a trailing
// comma, so gating the strip on a `//` made the bridge refuse to edit a file
// its own client accepts. (A UTF-8 BOM is dropped one layer up, by
// readConfigFile, so every format's editor sees the document itself.)
func TestParseJSONConfigAcceptsATrailingCommaWithoutComments(t *testing.T) {
	cases := map[string]string{
		"object": "{\n  \"servers\": {},\n}\n",
		"array":  "{\n  \"list\": [1, 2,]\n}\n",
	}
	for name, raw := range cases {
		t.Run(name, func(t *testing.T) {
			if _, err := parseJSONConfig(raw); err != nil {
				t.Fatalf("parseJSONConfig: %v", err)
			}
		})
	}
}
