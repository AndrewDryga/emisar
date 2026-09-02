package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"runtime"
	"sort"
	"strings"
	"time"
)

const (
	listPacksToolName   = "list_packs"
	listRunnersToolName = "list_runners"
	maxCLIFleetLabels   = 12
	maxCLIFleetPacks    = 12
	maxCLIFleetIssues   = 5
	maxCLIFleetRefRunes = 320
	maxCLIFleetCommand  = 8192
)

type cliFleetIssue struct {
	Message string `json:"message"`
}

type cliFleetRunner struct {
	Name              string            `json:"name"`
	Status            string            `json:"status"`
	Group             string            `json:"group"`
	Hostname          string            `json:"hostname"`
	Labels            map[string]string `json:"labels"`
	Packs             []string          `json:"packs"`
	PacksNext         cliToolResultNext `json:"packs_next"`
	LastSeenAt        string            `json:"last_seen_at"`
	RunnerRef         string            `json:"runner_ref"`
	EnforceSignatures bool              `json:"enforce_signatures"`
	Issues            []cliFleetIssue   `json:"issues"`
}

type cliFleetPackAction struct {
	Availability string `json:"availability"`
}

type cliFleetPack struct {
	PackRef      string               `json:"pack_ref"`
	Availability string               `json:"availability"`
	Issues       []cliFleetIssue      `json:"issues"`
	Actions      []cliFleetPackAction `json:"actions"`
}

type cliFleetAction struct {
	ActionID string            `json:"action_id"`
	PackRef  string            `json:"pack_ref"`
	Title    string            `json:"title"`
	Summary  string            `json:"summary"`
	Risk     string            `json:"risk"`
	Next     cliToolResultNext `json:"next"`
}

func writeCLIFleetOutput(w io.Writer, toolName string, arguments, raw []byte, account string) (bool, error) {
	if err := validateStrictJSON(raw); err != nil {
		return false, nil
	}

	var rendered string
	var ok bool
	switch toolName {
	case listRunnersToolName:
		rendered, ok = renderCLIListRunners(w, raw, account)
	case listPacksToolName:
		rendered, ok = renderCLIListPacks(w, arguments, raw, account)
	case findActionsToolName:
		rendered, ok = renderCLIFindActions(w, arguments, raw, account)
	default:
		return false, nil
	}
	if !ok {
		return false, nil
	}
	_, err := io.WriteString(w, rendered)
	return true, err
}

func renderCLIListRunners(w io.Writer, raw []byte, account string) (string, bool) {
	var result struct {
		OK      bool `json:"ok"`
		Summary struct {
			Matched      int `json:"matched"`
			Connected    int `json:"connected"`
			Disconnected int `json:"disconnected"`
			Pending      int `json:"pending"`
			Disabled     int `json:"disabled"`
		} `json:"summary"`
		RunnersRaw json.RawMessage `json:"runners"`
		NextCursor json.RawMessage `json:"next_cursor"`
	}
	if err := json.Unmarshal(raw, &result); err != nil || !result.OK ||
		firstJSONByte(result.RunnersRaw) != '[' {
		return "", false
	}
	var runners []cliFleetRunner
	if err := json.Unmarshal(result.RunnersRaw, &runners); err != nil {
		return "", false
	}
	for _, runner := range runners {
		if runner.Name == "" || runner.Status == "" || runner.RunnerRef == "" {
			return "", false
		}
	}
	if len(runners) == 0 {
		return "No runners found.\n", true
	}

	var out strings.Builder
	matched := max(result.Summary.Matched, len(runners))
	shown := runners[:min(len(runners), maxCLIResultItems)]
	if matched > len(shown) || hasJSONValue(result.NextCursor) {
		fmt.Fprintf(&out, "Showing %d of %d runners", len(shown), matched)
	} else {
		fmt.Fprintf(&out, "%d %s", matched, plural(matched, "runner", "runners"))
	}
	counts := []struct {
		value  int
		status string
	}{
		{result.Summary.Connected, "connected"},
		{result.Summary.Disconnected, "disconnected"},
		{result.Summary.Pending, "pending"},
		{result.Summary.Disabled, "disabled"},
	}
	var summaries []string
	for _, count := range counts {
		if count.value > 0 {
			summaries = append(summaries, fmt.Sprintf("%d %s", count.value, cliFleetStatus(w, count.status)))
		}
	}
	if len(summaries) > 0 {
		out.WriteString(" — ")
		out.WriteString(strings.Join(summaries, ", "))
	}
	out.WriteString("\n")

	for _, runner := range shown {
		out.WriteString("\n")
		out.WriteString(cliStyledText(w, "1", cliInlineText(runner.Name, 120)))
		out.WriteString(" — ")
		out.WriteString(cliFleetStatus(w, runner.Status))
		out.WriteString("\n")

		location := cliInlineText(runner.Hostname, maxCLIHumanStringRunes)
		group := cliInlineText(runner.Group, 120)
		if location != "" || group != "" {
			out.WriteString("  ")
			out.WriteString(location)
			if location != "" && group != "" {
				out.WriteString(" · ")
			}
			if group != "" {
				out.WriteString("group ")
				out.WriteString(group)
			}
			out.WriteString("\n")
		}
		if labels := cliFleetLabels(runner.Labels); labels != "" {
			fmt.Fprintf(&out, "  Labels  %s\n", labels)
		}
		if packs := cliFleetValues(runner.Packs, maxCLIFleetPacks); packs != "" {
			fmt.Fprintf(&out, "  Packs  %s\n", packs)
		}
		if command := cliFleetRunnerPacksCommand(runner, account); command != "" {
			fmt.Fprintf(&out, "  See packs  %s\n", command)
		}
		if lastSeen := cliFleetTime(runner.LastSeenAt); lastSeen != "" {
			fmt.Fprintf(&out, "  Last seen  %s\n", lastSeen)
		}
		fmt.Fprintf(&out, "  Runner ref  %s\n", cliInlineText(runner.RunnerRef, maxCLIFleetRefRunes))
		if runner.EnforceSignatures {
			out.WriteString("  Dispatch signatures required.\n")
		}
		writeCLIFleetIssues(&out, w, runner.Issues)
	}
	if hasJSONValue(result.NextCursor) || len(runners) > maxCLIResultItems {
		out.WriteString("\nMore runners are available. Use --json to continue with the returned cursor.\n")
	}
	return out.String(), true
}

func renderCLIListPacks(w io.Writer, arguments, raw []byte, account string) (string, bool) {
	var result struct {
		OK         bool            `json:"ok"`
		PacksRaw   json.RawMessage `json:"packs"`
		NextCursor json.RawMessage `json:"next_cursor"`
	}
	if err := json.Unmarshal(raw, &result); err != nil || !result.OK ||
		firstJSONByte(result.PacksRaw) != '[' {
		return "", false
	}
	var packs []cliFleetPack
	if err := json.Unmarshal(result.PacksRaw, &packs); err != nil {
		return "", false
	}
	for _, pack := range packs {
		if pack.PackRef == "" || pack.Availability == "" {
			return "", false
		}
	}
	if len(packs) == 0 {
		var input struct {
			Include string `json:"include"`
		}
		_ = json.Unmarshal(arguments, &input)
		switch input.Include {
		case "all":
			return "No trusted packs found.\n", true
		case "unavailable":
			return "No trusted unavailable packs found.\n", true
		}
		command := cliToolInvocationForOS(listPacksToolName, account, runtime.GOOS) +
			" " + shellQuote(`{"include":"all"}`)
		return "No executable packs found.\n\nUse `" + command + "` to include trusted unavailable packs.\n", true
	}

	var out strings.Builder
	fmt.Fprintf(&out, "%d %s\n", len(packs), plural(len(packs), "pack", "packs"))
	for _, pack := range packs[:min(len(packs), maxCLIResultItems)] {
		out.WriteString("\n")
		out.WriteString(cliStyledText(w, "1", cliFleetPackName(pack.PackRef)))
		out.WriteString(" — ")
		out.WriteString(cliFleetStatus(w, pack.Availability))
		out.WriteString("\n")
		fmt.Fprintf(&out, "  %s\n", cliFleetActionCount(pack.Actions))
		fmt.Fprintf(&out, "  Pack ref  %s\n", cliInlineText(pack.PackRef, maxCLIFleetRefRunes))
		if command := cliFleetPackActionsCommandForOS(pack.PackRef, account, runtime.GOOS); command != "" {
			fmt.Fprintf(&out, "  Actions  %s\n", command)
		}
		writeCLIFleetIssues(&out, w, pack.Issues)
	}
	if hasJSONValue(result.NextCursor) || len(packs) > maxCLIResultItems {
		out.WriteString("\nMore packs are available. Use --json to continue with the returned cursor.\n")
	}
	return out.String(), true
}

func cliFleetPackActionsCommandForOS(packRef, account, goos string) string {
	if packRef == "" || len(packRef) > maxCLIFleetRefRunes || terminalSafeLine(packRef) != packRef {
		return ""
	}
	arguments, err := json.Marshal(struct {
		PackRef string `json:"pack_ref"`
	}{PackRef: packRef})
	if err != nil {
		return ""
	}
	return cliFleetNextCommandForOS(cliToolResultNext{
		Tool:      findActionsToolName,
		Arguments: arguments,
	}, findActionsToolName, account, goos)
}

func renderCLIFindActions(w io.Writer, arguments, raw []byte, account string) (string, bool) {
	var result struct {
		OK            bool            `json:"ok"`
		CandidatesRaw json.RawMessage `json:"candidates"`
		Next          json.RawMessage `json:"next"`
	}
	if err := json.Unmarshal(raw, &result); err != nil || !result.OK ||
		firstJSONByte(result.CandidatesRaw) != '[' {
		return "", false
	}
	var candidates []cliFleetAction
	if err := json.Unmarshal(result.CandidatesRaw, &candidates); err != nil {
		return "", false
	}
	for _, candidate := range candidates {
		if candidate.ActionID == "" || candidate.PackRef == "" || candidate.Risk == "" {
			return "", false
		}
	}

	var input struct {
		Query string `json:"query"`
	}
	_ = json.Unmarshal(arguments, &input)
	query := cliInlineText(input.Query, maxCLIHumanStringRunes)
	if len(candidates) == 0 {
		if query == "" {
			return "No matching actions found.\n", true
		}
		return fmt.Sprintf("No matching actions found for %q.\n", query), true
	}

	var out strings.Builder
	fmt.Fprintf(&out, "%d %s found", len(candidates), plural(len(candidates), "action", "actions"))
	if query != "" {
		fmt.Fprintf(&out, " for %q", query)
	}
	out.WriteString(".\n")
	for _, candidate := range candidates[:min(len(candidates), maxCLIResultItems)] {
		out.WriteString("\n")
		out.WriteString(cliStyledText(w, "1", cliInlineText(candidate.ActionID, 128)))
		if title := cliInlineText(candidate.Title, maxCLIHumanStringRunes); title != "" {
			out.WriteString(" — ")
			out.WriteString(title)
		}
		out.WriteString("\n")
		if summary := cliInlineText(candidate.Summary, maxCLIHumanStringRunes); summary != "" {
			fmt.Fprintf(&out, "  %s\n", summary)
		}
		fmt.Fprintf(
			&out,
			"  %s · pack %s\n",
			cliFleetRisk(w, candidate.Risk),
			cliInlineText(candidate.PackRef, maxCLIFleetRefRunes),
		)
		if command := cliFleetActionInspectCommand(candidate, account); command != "" {
			fmt.Fprintf(&out, "  Inspect  %s\n", command)
		}
	}
	if hasJSONValue(result.Next) || len(candidates) > maxCLIResultItems {
		out.WriteString("\nMore actions are available. Use --json to continue with the returned next call.\n")
	}
	return out.String(), true
}

func cliFleetStatus(w io.Writer, value string) string {
	value = cliInlineText(value, 40)
	switch value {
	case "connected", "executable":
		return cliStyledText(w, "32", value)
	case "disconnected", "pending", "unavailable":
		return cliStyledText(w, "33", value)
	case "disabled":
		return cliStyledText(w, "2", value)
	default:
		return value
	}
}

func cliFleetRisk(w io.Writer, value string) string {
	value = cliInlineText(value, 40)
	label := value + " risk"
	switch value {
	case "low":
		return cliStyledText(w, "32", label)
	case "medium":
		return cliStyledText(w, "33", label)
	case "high":
		return cliStyledText(w, "31", label)
	default:
		return label
	}
}

// cliInlineText bounds a server string to one terminal-safe line of at most
// limit runes. One definition: cli_fleet and cli_runbooks each carried their
// own spelling of it.
func cliInlineText(value string, limit int) string {
	value = terminalSafeLine(value)
	runes := []rune(value)
	if len(runes) > limit {
		return string(runes[:limit]) + "…"
	}
	return value
}

func cliFleetTime(value string) string {
	parsed, err := time.Parse(time.RFC3339Nano, value)
	if err != nil {
		return cliInlineText(value, 80)
	}
	return parsed.UTC().Format("2006-01-02 15:04 UTC")
}

func cliFleetLabels(labels map[string]string) string {
	if len(labels) == 0 {
		return ""
	}
	keys := make([]string, 0, len(labels))
	for key := range labels {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	values := make([]string, 0, min(len(keys), maxCLIFleetLabels)+1)
	for _, key := range keys[:min(len(keys), maxCLIFleetLabels)] {
		values = append(values, cliInlineText(key, 80)+"="+cliInlineText(labels[key], 120))
	}
	if len(keys) > maxCLIFleetLabels {
		values = append(values, fmt.Sprintf("+%d more", len(keys)-maxCLIFleetLabels))
	}
	return strings.Join(values, " · ")
}

func cliFleetValues(values []string, limit int) string {
	if len(values) == 0 {
		return ""
	}
	displayed := make([]string, 0, min(len(values), limit)+1)
	for _, value := range values[:min(len(values), limit)] {
		displayed = append(displayed, cliInlineText(value, 80))
	}
	if len(values) > limit {
		displayed = append(displayed, fmt.Sprintf("+%d more", len(values)-limit))
	}
	return strings.Join(displayed, ", ")
}

func writeCLIFleetIssues(out *strings.Builder, w io.Writer, issues []cliFleetIssue) {
	for _, issue := range issues[:min(len(issues), maxCLIFleetIssues)] {
		message := cliInlineText(issue.Message, maxCLIHumanStringRunes)
		if message != "" {
			fmt.Fprintf(out, "  %s  %s\n", cliStyledText(w, "33", "Issue"), message)
		}
	}
	if len(issues) > maxCLIFleetIssues {
		fmt.Fprintf(out, "  %d more issues; use --json for the complete result.\n", len(issues)-maxCLIFleetIssues)
	}
}

func cliFleetPackName(packRef string) string {
	safe := cliInlineText(packRef, maxCLIFleetRefRunes)
	identity, _, found := strings.Cut(safe, "/")
	if !found {
		return safe
	}
	packID, version, found := strings.Cut(identity, "@")
	if !found || packID == "" || version == "" {
		return safe
	}
	return packID + " " + version
}

func cliFleetActionCount(actions []cliFleetPackAction) string {
	counts := map[string]int{}
	for _, action := range actions {
		counts[action.Availability]++
	}
	if len(actions) == 0 {
		return "No actions in this view."
	}
	if counts["executable"] == len(actions) {
		return fmt.Sprintf("%d executable %s", len(actions), plural(len(actions), "action", "actions"))
	}
	parts := make([]string, 0, 3)
	for _, availability := range []string{"executable", "unavailable"} {
		if count := counts[availability]; count > 0 {
			parts = append(parts, fmt.Sprintf("%d %s", count, availability))
		}
	}
	other := len(actions) - counts["executable"] - counts["unavailable"]
	if other > 0 {
		parts = append(parts, fmt.Sprintf("%d other", other))
	}
	return strings.Join(parts, ", ") + " actions"
}

func cliFleetNextCommandForOS(next cliToolResultNext, expectedTool, account, goos string) string {
	if next.Tool != expectedTool || expectedTool == "" || len(next.Tool) > 128 ||
		terminalSafeLine(next.Tool) != next.Tool ||
		firstJSONByte(next.Arguments) != '{' || len(next.Arguments) > maxCLIFleetCommand ||
		validateStrictJSON(next.Arguments) != nil {
		return ""
	}
	var compact bytes.Buffer
	if err := json.Compact(&compact, next.Arguments); err != nil {
		return ""
	}
	arguments := compact.String()
	if terminalSafeText(arguments) != arguments {
		return ""
	}
	return cliToolInvocationForOS(next.Tool, account, goos) + " " + shellQuoteForOS(arguments, goos)
}

func cliFleetRunnerPacksCommand(runner cliFleetRunner, account string) string {
	var arguments struct {
		RunnerRefs []string `json:"runner_refs"`
	}
	if json.Unmarshal(runner.PacksNext.Arguments, &arguments) != nil ||
		len(arguments.RunnerRefs) != 1 || arguments.RunnerRefs[0] != runner.RunnerRef {
		return ""
	}
	return cliFleetNextCommandForOS(runner.PacksNext, listPacksToolName, account, runtime.GOOS)
}

func cliFleetActionInspectCommand(candidate cliFleetAction, account string) string {
	var arguments struct {
		ActionID string `json:"action_id"`
		PackRef  string `json:"pack_ref"`
	}
	if json.Unmarshal(candidate.Next.Arguments, &arguments) != nil ||
		arguments.ActionID != candidate.ActionID || arguments.PackRef != candidate.PackRef {
		return ""
	}
	return cliFleetNextCommandForOS(candidate.Next, "get_action", account, runtime.GOOS)
}

func hasJSONValue(raw json.RawMessage) bool {
	first := firstJSONByte(raw)
	return first != 0 && first != 'n'
}

func plural(count int, singular, plural string) string {
	if count == 1 {
		return singular
	}
	return plural
}
