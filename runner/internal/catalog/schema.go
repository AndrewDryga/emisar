package catalog

import _ "embed"

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

// Schemas returns the object-name → bytes map of published JSON schemas.
func Schemas() map[string][]byte {
	return map[string][]byte{
		"catalog.schema.json": catalogSchema,
		"pack.schema.json":    packSchema,
		"action.schema.json":  actionSchema,
	}
}
