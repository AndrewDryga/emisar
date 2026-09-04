package catalog

import (
	_ "embed"
	"encoding/json"
	"fmt"

	"github.com/santhosh-tekuri/jsonschema/v6"
)

// The JSON schemas published alongside the catalog: the catalog.json output
// contract (machine consumers), and the pack/action authoring schemas
// (editor validation + documentation). They are validation aids only — the
// security trust source is pack bytes → the runner-compatible content hash,
// never a schema check.

//go:embed schemas/catalog.schema.json
var catalogSchema []byte

//go:embed schemas/pack.schema.json
var packSchema []byte

//go:embed schemas/action.schema.json
var actionSchema []byte

// SchemaArtifactVersion versions the immutable authoring-schema suite. Bump it
// whenever any embedded schema changes, then update each schema's $id to the
// matching published object path. Older schema objects remain permanently
// available under their prior filenames.
const SchemaArtifactVersion = 7

// Schemas returns the object-name → bytes map of published JSON schemas.
func Schemas() map[string][]byte {
	return map[string][]byte{
		schemaObjectName("catalog"): catalogSchema,
		schemaObjectName("pack"):    packSchema,
		schemaObjectName("action"):  actionSchema,
	}
}

func schemaObjectName(kind string) string {
	return fmt.Sprintf("%s.v%d.schema.json", kind, SchemaArtifactVersion)
}

// ValidateCatalogDocument checks raw catalog.json bytes against the embedded
// catalog schema — the same contract published to machine consumers.
//
// It exists so that packctl's `--previous` acceptance and CD's fallback
// decision cannot drift apart. Both call this; neither hand-rolls a predicate.
// The shallow jq check CD used before (`schema_version == 1 and packs
// non-empty`) accepted a catalog whose `previous_versions` had been truncated,
// and `--previous` accepted anything that merely unmarshalled — so a subtly
// corrupt history was carried forward silently, amputating pack version windows
// on the way through.
//
// This is a structural aid, not a trust boundary: the security root stays pack
// bytes → content hash, exactly as the schema comment above says.
func ValidateCatalogDocument(data []byte) error {
	var doc any
	if err := json.Unmarshal(data, &doc); err != nil {
		return fmt.Errorf("parse catalog document: %w", err)
	}

	compiler := jsonschema.NewCompiler()

	var schemaDoc any
	if err := json.Unmarshal(catalogSchema, &schemaDoc); err != nil {
		return fmt.Errorf("parse embedded catalog schema: %w", err)
	}
	if err := compiler.AddResource(catalogSchemaURL, schemaDoc); err != nil {
		return fmt.Errorf("load embedded catalog schema: %w", err)
	}
	compiled, err := compiler.Compile(catalogSchemaURL)
	if err != nil {
		return fmt.Errorf("compile embedded catalog schema: %w", err)
	}

	if err := compiled.Validate(doc); err != nil {
		return fmt.Errorf("catalog document does not match the published schema: %w", err)
	}
	return nil
}

const catalogSchemaURL = "https://emisar.dev/schemas/catalog.schema.json"
