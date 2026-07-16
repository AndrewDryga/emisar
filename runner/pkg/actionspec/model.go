package actionspec

import "strings"

// ModelDescriptor is the canonical, reviewed action contract. Registry
// publication stores it in the trusted manifest and runner advertisements use
// the same projection as deployment evidence, so exact-hash comparisons cannot
// drift between serializers.
type ModelDescriptor struct {
	ID          string         `json:"id"`
	Title       string         `json:"title"`
	Summary     string         `json:"summary"`
	Description string         `json:"description"`
	Kind        string         `json:"kind"`
	Risk        string         `json:"risk"`
	SideEffects []string       `json:"side_effects"`
	Args        []ModelArg     `json:"args"`
	Examples    []ModelExample `json:"examples"`
	SearchTerms []string       `json:"search_terms"`
}

// ModelArg is the JSON-safe public argument contract. Durations are strings,
// matching the authored YAML and avoiding Go's integer duration encoding.
type ModelArg struct {
	Name        string           `json:"name"`
	Type        string           `json:"type"`
	Required    bool             `json:"required"`
	Sensitive   bool             `json:"sensitive,omitempty"`
	Default     any              `json:"default,omitempty"`
	Description string           `json:"description,omitempty"`
	Validation  *ModelValidation `json:"validation,omitempty"`
}

// ModelValidation is the serializable subset of argument validation.
type ModelValidation struct {
	Enum            []any    `json:"enum,omitempty"`
	Pattern         string   `json:"pattern,omitempty"`
	Min             *float64 `json:"min,omitempty"`
	Max             *float64 `json:"max,omitempty"`
	Allowed         []any    `json:"allowed,omitempty"`
	AllowedPaths    []string `json:"allowed_paths,omitempty"`
	DeniedPaths     []string `json:"denied_paths,omitempty"`
	AllowedPrefixes []string `json:"allowed_prefixes,omitempty"`
	DeniedPrefixes  []string `json:"denied_prefixes,omitempty"`
	MaxItems        *int     `json:"max_items,omitempty"`
	MaxLength       *int     `json:"max_length,omitempty"`
	MinDuration     *string  `json:"min_duration,omitempty"`
	MaxDuration     *string  `json:"max_duration,omitempty"`
}

// ModelExample is one reviewed sample invocation.
type ModelExample struct {
	Title string         `json:"title"`
	Args  map[string]any `json:"args"`
}

// ModelDescriptor returns the canonical model-facing projection of a validated
// action. Callers obtain actions from the pack loader, which runs Validate first.
func (a *Action) ModelDescriptor() ModelDescriptor {
	summary, _ := a.ModelSummary()

	return ModelDescriptor{
		ID:          a.ID,
		Title:       normalizeModelText(a.Title),
		Summary:     summary,
		Description: normalizeModelText(a.Description),
		Kind:        string(a.Kind),
		Risk:        string(a.Risk),
		SideEffects: modelSideEffects(a.SideEffects),
		Args:        modelArgs(a.Args),
		Examples:    modelExamples(a.Examples),
		SearchTerms: normalizedModelStrings(a.SearchTerms),
	}
}

// ModelSummary returns the explicit summary or a bounded first-sentence
// derivation from the description.
func (a *Action) ModelSummary() (string, error) {
	if summary := normalizeModelText(a.Summary); summary != "" {
		return summary, nil
	}

	description := normalizeModelText(a.Description)
	if len(description) <= 512 {
		return description, nil
	}
	for i, r := range description {
		end := i + len(string(r))
		if end > 512 {
			break
		}
		if strings.ContainsRune(".!?", r) && (end == len(description) || description[end] == ' ') {
			return description[:end], nil
		}
	}
	return "", modelSummaryError(a.ID)
}

func modelSideEffects(values []string) []string {
	out := normalizedModelStrings(values)
	if len(out) == 1 && strings.EqualFold(out[0], "none") {
		return []string{}
	}
	return out
}

func modelArgs(args []Arg) []ModelArg {
	out := make([]ModelArg, 0, len(args))
	for _, arg := range args {
		out = append(out, ModelArg{
			Name:        arg.Name,
			Type:        string(arg.Type),
			Required:    arg.Required,
			Sensitive:   arg.Sensitive,
			Default:     arg.Default,
			Description: normalizeModelText(arg.Description),
			Validation:  modelValidation(arg.Validation),
		})
	}
	return out
}

func modelValidation(validation *Validation) *ModelValidation {
	if validation == nil {
		return nil
	}
	return &ModelValidation{
		Enum:            validation.Enum,
		Pattern:         validation.Pattern,
		Min:             validation.Min,
		Max:             validation.Max,
		Allowed:         validation.Allowed,
		AllowedPaths:    validation.AllowedPaths,
		DeniedPaths:     validation.DeniedPaths,
		AllowedPrefixes: validation.AllowedPrefixes,
		DeniedPrefixes:  validation.DeniedPrefixes,
		MaxItems:        validation.MaxItems,
		MaxLength:       validation.MaxLength,
		MinDuration:     modelDuration(validation.MinDuration),
		MaxDuration:     modelDuration(validation.MaxDuration),
	}
}

func modelDuration(duration *Duration) *string {
	if duration == nil {
		return nil
	}
	value := duration.String()
	return &value
}

func modelExamples(examples []Example) []ModelExample {
	out := make([]ModelExample, 0, len(examples))
	for _, example := range examples {
		args := example.Args
		if args == nil {
			args = map[string]any{}
		}
		out = append(out, ModelExample{
			Title: normalizeModelText(example.Title),
			Args:  args,
		})
	}
	return out
}

func normalizedModelStrings(values []string) []string {
	out := make([]string, 0, len(values))
	for _, value := range values {
		out = append(out, normalizeModelText(value))
	}
	return out
}
