package tree_sitter_rail_test

import (
	"testing"

	tree_sitter "github.com/smacker/go-tree-sitter"
	tree_sitter_rail "github.com/zemo-g/rail/tree-sitter-rail/bindings/go"
)

func TestCanLoadGrammar(t *testing.T) {
	language := tree_sitter.NewLanguage(tree_sitter_rail.Language())
	if language == nil {
		t.Errorf("Error loading Rail grammar")
	}
}
