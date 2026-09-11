package main

import (
	"encoding/json"
	"fmt"
	"sort"
	"strings"
)

// The JSON-Schema introspector behind `emisar-mcp <tool> --help`: it walks a
// tool's input schema and names its top-level arguments, their types, and
// their constraints. Pure map[string]any traversal, split out of cli.go —
// mcp/AGENTS.md's rule that an unsupported schema shape points the operator at
// the exact `--json` descriptor is reviewable here in one file.

type cliArgument struct {
	Name        string
	Type        string
	Required    bool
	Default     string
	Description string
	Constraints string
}

func describeTopLevelArguments(schema map[string]any) ([]cliArgument, bool, bool) {
	properties := make(map[string]any)
	required := make(map[string]bool)
	if !collectTopLevelSchema(schema, schema, properties, required, map[string]bool{}, 0) {
		return nil, false, false
	}
	crossFieldRules, ok := hasCrossFieldRules(schema, schema, map[string]bool{}, 0)
	if !ok {
		return nil, false, false
	}
	names := make([]string, 0, len(properties))
	for name := range properties {
		names = append(names, name)
	}
	sort.Slice(names, func(i, j int) bool {
		if required[names[i]] != required[names[j]] {
			return required[names[i]]
		}
		return names[i] < names[j]
	})

	arguments := make([]cliArgument, 0, len(names))
	for _, name := range names {
		property, ok := properties[name].(map[string]any)
		if !ok {
			return nil, false, false
		}
		resolved, ok := resolveSchema(property, schema, map[string]bool{}, 0)
		if !ok {
			return nil, false, false
		}
		argumentType, ok := schemaType(resolved, schema, 0)
		if !ok {
			return nil, false, false
		}
		constraints, ok := schemaConstraints(resolved, schema, 0)
		if !ok {
			return nil, false, false
		}
		arguments = append(arguments, cliArgument{
			Name:        name,
			Type:        argumentType,
			Required:    required[name],
			Default:     schemaJSONValue(resolved["default"]),
			Description: stringValue(resolved["description"]),
			Constraints: constraints,
		})
	}
	return arguments, crossFieldRules, true
}

func collectTopLevelSchema(
	schema, root map[string]any,
	properties map[string]any,
	required map[string]bool,
	seen map[string]bool,
	depth int,
) bool {
	if depth > maxCLISchemaRenderDepth {
		return false
	}
	if ref, ok := schema["$ref"].(string); ok {
		if seen[ref] {
			return false
		}
		target, ok := resolveReference(ref, root)
		if !ok {
			return false
		}
		seen[ref] = true
		defer delete(seen, ref)
		if !collectTopLevelSchema(target, root, properties, required, seen, depth+1) {
			return false
		}
	}
	if direct, ok := schema["properties"].(map[string]any); ok {
		for name, property := range direct {
			properties[name] = property
		}
	}
	if values, ok := schema["required"].([]any); ok {
		for _, value := range values {
			if name, ok := value.(string); ok {
				required[name] = true
			}
		}
	}
	if allOf, ok := schema["allOf"].([]any); ok {
		for _, item := range allOf {
			child, ok := item.(map[string]any)
			if !ok || !collectTopLevelSchema(child, root, properties, required, seen, depth+1) {
				return false
			}
		}
	}
	return true
}

func hasCrossFieldRules(schema, root map[string]any, seen map[string]bool, depth int) (bool, bool) {
	if depth > maxCLISchemaRenderDepth {
		return false, false
	}
	for _, keyword := range []string{
		"oneOf", "anyOf", "not", "if", "then", "else", "dependentRequired", "dependentSchemas",
	} {
		if _, present := schema[keyword]; present {
			return true, true
		}
	}
	if ref, ok := schema["$ref"].(string); ok {
		if seen[ref] {
			return false, false
		}
		target, ok := resolveReference(ref, root)
		if !ok {
			return false, false
		}
		seen[ref] = true
		found, ok := hasCrossFieldRules(target, root, seen, depth+1)
		delete(seen, ref)
		if !ok || found {
			return found, ok
		}
	}
	if allOf, ok := schema["allOf"].([]any); ok {
		for _, item := range allOf {
			child, ok := item.(map[string]any)
			if !ok {
				return false, false
			}
			found, ok := hasCrossFieldRules(child, root, seen, depth+1)
			if !ok || found {
				return found, ok
			}
		}
	}
	return false, true
}

func resolveSchema(schema, root map[string]any, seen map[string]bool, depth int) (map[string]any, bool) {
	if depth > maxCLISchemaRenderDepth {
		return nil, false
	}
	resolved := make(map[string]any, len(schema))
	if ref, ok := schema["$ref"].(string); ok {
		if seen[ref] {
			return nil, false
		}
		target, ok := resolveReference(ref, root)
		if !ok {
			return nil, false
		}
		seen[ref] = true
		target, ok = resolveSchema(target, root, seen, depth+1)
		delete(seen, ref)
		if !ok {
			return nil, false
		}
		for key, value := range target {
			resolved[key] = value
		}
	}
	for key, value := range schema {
		if key != "$ref" {
			resolved[key] = value
		}
	}
	return resolved, true
}

func resolveReference(ref string, root map[string]any) (map[string]any, bool) {
	const prefix = "#/$defs/"
	if !strings.HasPrefix(ref, prefix) {
		return nil, false
	}
	definitions, ok := root["$defs"].(map[string]any)
	if !ok {
		return nil, false
	}
	definition, ok := definitions[strings.TrimPrefix(ref, prefix)].(map[string]any)
	if !ok {
		return nil, false
	}
	return definition, true
}

func schemaType(schema, root map[string]any, depth int) (string, bool) {
	if depth > maxCLISchemaRenderDepth {
		return "", false
	}
	if value := typeValue(schema["type"]); value != "" {
		if value == "array" {
			if items, ok := schema["items"].(map[string]any); ok {
				resolved, ok := resolveSchema(items, root, map[string]bool{}, depth+1)
				if !ok {
					return "", false
				}
				itemType, ok := schemaType(resolved, root, depth+1)
				if !ok {
					return "", false
				}
				return "array<" + itemType + ">", true
			}
		}
		return value, true
	}
	for _, keyword := range []string{"oneOf", "anyOf"} {
		variants, ok := schema[keyword].([]any)
		if !ok {
			continue
		}
		var types []string
		for _, variant := range variants {
			child, ok := variant.(map[string]any)
			if !ok {
				return "", false
			}
			resolved, ok := resolveSchema(child, root, map[string]bool{}, depth+1)
			if !ok {
				return "", false
			}
			variantType, ok := schemaType(resolved, root, depth+1)
			if !ok {
				return "", false
			}
			types = appendUnique(types, variantType)
		}
		if len(types) > 0 {
			return strings.Join(types, " | "), true
		}
	}
	return "JSON", true
}

func typeValue(value any) string {
	switch value := value.(type) {
	case string:
		return value
	case []any:
		var values []string
		for _, item := range value {
			if name, ok := item.(string); ok {
				values = appendUnique(values, name)
			}
		}
		return strings.Join(values, " | ")
	default:
		return ""
	}
}

func schemaConstraints(schema, root map[string]any, depth int) (string, bool) {
	if depth > maxCLISchemaRenderDepth {
		return "", false
	}
	var constraints []string
	if enum, ok := schema["enum"].([]any); ok {
		values := make([]string, 0, len(enum))
		for _, value := range enum {
			values = append(values, schemaJSONValue(value))
		}
		constraints = append(constraints, "one of "+strings.Join(values, ", "))
	}
	constraints = appendRange(constraints, schema, "minimum", "maximum", "value")
	constraints = appendRange(constraints, schema, "minLength", "maxLength", "characters")
	constraints = appendRange(constraints, schema, "minItems", "maxItems", "items")
	if pattern := stringValue(schema["pattern"]); pattern != "" {
		constraints = append(constraints, "pattern "+pattern)
	}
	if items, ok := schema["items"].(map[string]any); ok {
		resolved, ok := resolveSchema(items, root, map[string]bool{}, depth+1)
		if !ok {
			return "", false
		}
		itemConstraints, ok := schemaConstraints(resolved, root, depth+1)
		if !ok {
			return "", false
		}
		if itemConstraints != "" {
			constraints = append(constraints, "each item: "+itemConstraints)
		}
	}
	return strings.Join(constraints, "; "), true
}

func appendRange(constraints []string, schema map[string]any, minimum, maximum, unit string) []string {
	min, hasMin := schema[minimum]
	max, hasMax := schema[maximum]
	switch {
	case hasMin && hasMax:
		return append(constraints, fmt.Sprintf("%s %s–%s", unit, schemaJSONValue(min), schemaJSONValue(max)))
	case hasMin:
		return append(constraints, fmt.Sprintf("%s at least %s", unit, schemaJSONValue(min)))
	case hasMax:
		return append(constraints, fmt.Sprintf("%s at most %s", unit, schemaJSONValue(max)))
	default:
		return constraints
	}
}

func schemaJSONValue(value any) string {
	if value == nil {
		return ""
	}
	encoded, err := json.Marshal(value)
	if err != nil {
		return ""
	}
	return string(encoded)
}
