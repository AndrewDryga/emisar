package expressions

import "testing"

// a boolean arg interpolated into a /bin/sh -c pipeline
// renders to a literal, NON-EMPTY token ("true" or "false"), never to the
// empty string. The gotcha: in shell, both tokens are truthy — `[ -n "false" ]`
// and `if [ "$flag" ]` both succeed — so an action that gates behaviour on a
// bare `{{ args.flag }}` across the shell boundary fires on `false` too. The
// guard is to compare explicitly (`[ "{{ args.flag }}" = "true" ]`) or to
// prefer a numeric/enum arg over a bool when it crosses into /bin/sh.
//
// This pins the rendering (formatScalar in eval.go) the caveat rests on, so a
// change that ever made `false` render empty would surface here.
func TestRender_BooleanIsAlwaysTruthyShellToken(t *testing.T) {
	cases := []struct {
		in   bool
		want string
	}{
		{true, "flag=true"},
		{false, "flag=false"}, // the gotcha: false renders as a non-empty token
	}
	for _, c := range cases {
		got, err := Render("flag={{ args.flag }}", map[string]any{"flag": c.in})
		if err != nil {
			t.Fatalf("render(flag=%v): %v", c.in, err)
		}
		if got != c.want {
			t.Fatalf("render(flag=%v) = %q, want %q", c.in, got, c.want)
		}
		// The substituted token must be non-empty for BOTH values — that
		// non-emptiness is exactly why a bare bool reads truthy in shell.
		token := got[len("flag="):]
		if token == "" {
			t.Fatalf("bool %v rendered to an empty token; a shell `[ -n ... ]` guard depends on it being non-empty", c.in)
		}
	}
}
