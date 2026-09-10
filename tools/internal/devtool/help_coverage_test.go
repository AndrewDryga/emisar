package devtool

import (
	"bytes"
	"go/ast"
	"go/parser"
	"go/token"
	"slices"
	"strings"
	"testing"
)

// The ./run surface is written down twice: a usage constant people read and a
// dispatcher that accepts the names. These tests read both and require them
// to agree, so a verb dropped from one side fails here instead of surfacing
// as "help advertises it, ./run says unknown command".

// documentedNames returns the first word of every two-space-indented line in
// a usage text: the names it advertises. Deeper indents are continuation
// lines and "./run …" examples are not names.
func documentedNames(usage string) []string {
	var names []string
	for _, line := range strings.Split(usage, "\n") {
		if !strings.HasPrefix(line, "  ") || strings.HasPrefix(line, "   ") {
			continue
		}
		name := strings.Fields(line)[0]
		if strings.HasPrefix(name, "./run") || slices.Contains(names, name) {
			continue
		}
		names = append(names, name)
	}
	slices.Sort(names)
	return names
}

// dispatchedNames returns the string literals a function's dispatcher accepts
// for its selector variable: every `case "name"` of a switch on it and every
// `selector == "name"` comparison. Reading the source keeps the test free of
// a fixture that could run each command.
func dispatchedNames(t *testing.T, file, function, selector string) []string {
	t.Helper()
	parsed, err := parser.ParseFile(token.NewFileSet(), file, nil, 0)
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	literal := func(expr ast.Expr) (string, bool) {
		lit, ok := expr.(*ast.BasicLit)
		if !ok || lit.Kind != token.STRING {
			return "", false
		}
		return strings.Trim(lit.Value, `"`), true
	}
	for _, decl := range parsed.Decls {
		fn, ok := decl.(*ast.FuncDecl)
		if !ok || fn.Name.Name != function {
			continue
		}
		ast.Inspect(fn.Body, func(node ast.Node) bool {
			switch node := node.(type) {
			case *ast.SwitchStmt:
				if tag, ok := node.Tag.(*ast.Ident); ok && tag.Name == selector {
					for _, clause := range node.Body.List {
						for _, expr := range clause.(*ast.CaseClause).List {
							if name, ok := literal(expr); ok {
								names = append(names, name)
							}
						}
					}
				}
			case *ast.BinaryExpr:
				if left, ok := node.X.(*ast.Ident); ok && node.Op == token.EQL && left.Name == selector {
					if name, ok := literal(node.Y); ok {
						names = append(names, name)
					}
				}
			}
			return true
		})
	}
	if len(names) == 0 {
		t.Fatalf("%s: no dispatch on %q found in %s", file, selector, function)
	}
	slices.Sort(names)
	return slices.Compact(names)
}

func TestMainHelpListsEveryDispatchedCommand(t *testing.T) {
	hidden := []string{"-h", "--help", "__browser-daemon"}
	dispatched := slices.DeleteFunc(dispatchedNames(t, "app.go", "Run", "command"), func(name string) bool {
		return slices.Contains(hidden, name)
	})
	if documented := documentedNames(usageText); !slices.Equal(documented, dispatched) {
		t.Fatalf("main help lists %v\nRun dispatches %v", documented, dispatched)
	}
	if !strings.Contains(usageText, "./run bootstrap") {
		t.Error("main help does not list the shell bootstrap")
	}
}

func TestTopicHelpListsEveryDispatchedTarget(t *testing.T) {
	for _, topic := range []struct {
		name, usage, file, function, selector string
	}{
		{"check", checkUsage, "portal.go", "check", "target"},
		{"test", testUsage, "gates.go", "test", "target"},
		{"gate", gateUsage, "gates.go", "gate", "target"},
		{"pack", packUsage, "pack.go", "pack", "action"},
	} {
		var out bytes.Buffer
		app := New(t.TempDir(), strings.NewReader(""), &out, &bytes.Buffer{})
		if err := app.Run(t.Context(), []string{"help", topic.name}); err != nil {
			t.Fatal(err)
		}
		if out.String() != topic.usage {
			t.Fatalf("help %s prints something other than %sUsage", topic.name, topic.name)
		}
		documented := documentedNames(topic.usage)
		dispatched := dispatchedNames(t, topic.file, topic.function, topic.selector)
		if !slices.Equal(documented, dispatched) {
			t.Errorf("help %s lists %v\n%s dispatches %v", topic.name, documented, topic.function, dispatched)
		}
	}
	if !strings.Contains(gateUsage, "portal [--changed]") {
		t.Fatal("gate help does not explain the affected-app mode")
	}
}
