package devtool

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

type screenshotTask struct {
	ID   string
	Path string
}

func activeScreenshotTasks(root string) ([]screenshotTask, error) {
	patterns := []string{
		filepath.Join(root, ".agent", "tasks", "10_in_progress", "*"),
		filepath.Join(root, "*", ".agent", "tasks", "10_in_progress", "*"),
	}
	var tasks []screenshotTask
	for _, pattern := range patterns {
		matches, err := filepath.Glob(pattern)
		if err != nil {
			return nil, fmt.Errorf("finding in-progress tasks: %w", err)
		}
		for _, match := range matches {
			info, err := os.Lstat(match)
			if err != nil {
				return nil, fmt.Errorf("stating task %s: %w", match, err)
			}
			if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
				continue
			}
			tasks = append(tasks, screenshotTask{ID: filepath.Base(match), Path: match})
		}
	}
	sort.Slice(tasks, func(i, j int) bool { return tasks[i].Path < tasks[j].Path })
	return tasks, nil
}

func (a *App) screenshotOutput(taskID, group string) (screenshotTask, string, error) {
	tasks, err := activeScreenshotTasks(a.Root)
	if err != nil {
		return screenshotTask{}, "", err
	}
	selected := tasks
	if taskID != "" {
		selected = nil
		for _, task := range tasks {
			if task.ID == taskID {
				selected = append(selected, task)
			}
		}
	}
	switch len(selected) {
	case 0:
		if taskID != "" {
			return screenshotTask{}, "", fmt.Errorf("task %q is not in progress; claim it before capturing screenshots", taskID)
		}
		return screenshotTask{}, "", fmt.Errorf(
			"screenshot proof requires an in-progress task; create and claim even a basic one first:\n" +
				"  coop tasks add --project <root|portal> \"Capture <subject>\"\n" +
				"  coop tasks claim <id>",
		)
	case 1:
	default:
		ids := make([]string, 0, len(selected))
		for _, task := range selected {
			ids = append(ids, task.ID)
		}
		return screenshotTask{}, "", fmt.Errorf(
			"multiple tasks are in progress (%s); choose the owner with --task <id>",
			strings.Join(ids, ", "),
		)
	}

	if group != "" && (!filepath.IsLocal(group) || filepath.Clean(group) == ".") {
		return screenshotTask{}, "", fmt.Errorf("screenshot group %q must stay inside the task", group)
	}
	output := filepath.Join(selected[0].Path, "screenshots")
	if group != "" {
		output = filepath.Join(output, filepath.Clean(group))
	}
	return selected[0], output, nil
}
