package ci

import (
	"context"
	"fmt"
	"strings"
)

func CheckFrozenMigrations(ctx context.Context, root, event, base string) error {
	if !validBase(ctx, root, base) {
		return fmt.Errorf("cannot verify frozen migrations: base commit is unavailable")
	}
	from, err := diffBase(ctx, root, event, base)
	if err != nil {
		return err
	}
	data, err := git(ctx, root, "diff", "--no-renames", "--name-status", "-z", "--diff-filter=MDRT", from, "HEAD", "--", ":(glob)portal/apps/*/priv/repo/migrations/[0-9]*.exs")
	if err != nil {
		return err
	}
	fields := nulStrings(data)
	if len(fields) == 0 {
		fmt.Println("ok: committed migrations are unchanged")
		return nil
	}
	violations := make([]string, 0, len(fields)/2)
	for index := 0; index+1 < len(fields); index += 2 {
		violations = append(violations, fields[index]+" "+fields[index+1])
	}
	return fmt.Errorf("committed migrations are frozen; add a new forward migration instead:\n  - %s", strings.Join(violations, "\n  - "))
}
