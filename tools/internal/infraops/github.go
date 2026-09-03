package infraops

import (
	"context"

	"github.com/andrewdryga/emisar/tools/internal/releaseenv"
)

func (a *App) verifyReleaseEnvironment(ctx context.Context, repo, environment string) error {
	return releaseenv.Verify(ctx, repo, environment, func(ctx context.Context, path string) ([]byte, error) {
		return a.output(ctx, a.Root, nil, "gh", "api",
			"-H", "Accept: application/vnd.github+json",
			"-H", "X-GitHub-Api-Version: 2022-11-28",
			path)
	}, a.Out)
}
