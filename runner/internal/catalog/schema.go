package catalog

import (
	_ "embed"
	"fmt"
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
const SchemaArtifactVersion = 3

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
