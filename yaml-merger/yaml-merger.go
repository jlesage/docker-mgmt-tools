package main

import (
	"fmt"
	"os"

	"gopkg.in/yaml.v3"
)

// deepCopyNode returns a deep copy of a yaml.Node
func deepCopyNode(n *yaml.Node) *yaml.Node {
	if n == nil {
		return nil
	}
	copy := *n
	if n.Content != nil {
		copy.Content = make([]*yaml.Node, len(n.Content))
		for i, c := range n.Content {
			copy.Content[i] = deepCopyNode(c)
		}
	}
	return &copy
}

// findKeyIndex returns the index of key node in mapping's Content slice (index of key node), or -1
func findKeyIndex(mapNode *yaml.Node, key string) int {
	if mapNode == nil || mapNode.Kind != yaml.MappingNode {
		return -1
	}
	for i := 0; i < len(mapNode.Content); i += 2 {
		k := mapNode.Content[i]
		if k.Kind == yaml.ScalarNode && k.Value == key {
			return i
		}
	}
	return -1
}

// mergeNodes merges node b into node a and returns a new node (does not mutate inputs)
func mergeNodes(a, b *yaml.Node) *yaml.Node {
	if b == nil {
		return deepCopyNode(a)
	}
	if a == nil {
		return deepCopyNode(b)
	}

	// If both are mapping nodes -> merge maps preserving order from a
	if a.Kind == yaml.MappingNode && b.Kind == yaml.MappingNode {
		return mergeMappingNodes(a, b)
	}

	// If both are sequence nodes -> merge sequences (handle keyed lists)
	if a.Kind == yaml.SequenceNode && b.Kind == yaml.SequenceNode {
		return mergeSequenceNodes(a, b)
	}

	// Otherwise scalar or differing kinds: take b (override)
	return deepCopyNode(b)
}

// mergeMappingNodes preserves order from a, then appends keys from b not present in a
func mergeMappingNodes(a, b *yaml.Node) *yaml.Node {
	out := &yaml.Node{Kind: yaml.MappingNode, Tag: "!!map"}

	// Track keys present in a
	keysInA := map[string]bool{}

	// Walk a's keys in order
	for i := 0; i < len(a.Content); i += 2 {
		keyNode := a.Content[i]
		valNode := a.Content[i+1]
		key := keyNode.Value
		keysInA[key] = true

		// If b has this key, merge values
		if j := findKeyIndex(b, key); j >= 0 {
			mergedVal := mergeNodes(valNode, b.Content[j+1])
			out.Content = append(out.Content, deepCopyNode(keyNode), mergedVal)
		} else {
			out.Content = append(out.Content, deepCopyNode(keyNode), deepCopyNode(valNode))
		}
	}

	// Append keys that are in b but not in a, preserving b order
	for i := 0; i < len(b.Content); i += 2 {
		keyNode := b.Content[i]
		if keysInA[keyNode.Value] {
			continue
		}
		out.Content = append(out.Content, deepCopyNode(keyNode), deepCopyNode(b.Content[i+1]))
	}

	return out
}

// detectKeyForSequence tries to find a common scalar key present in mapping elements of both sequences
func detectKeyForSequence(a, b *yaml.Node) string {
	// Prefer the first mapping field from the first non-empty sequence (a then b)
	pickFirstKey := func(seq *yaml.Node) string {
		if seq == nil || seq.Kind != yaml.SequenceNode {
			return ""
		}
		for _, item := range seq.Content {
			if item.Kind != yaml.MappingNode {
				continue
			}
			if len(item.Content) >= 2 {
				k := item.Content[0]
				if k.Kind == yaml.ScalarNode {
					return k.Value
				}
			}
		}
		return ""
	}

	if k := pickFirstKey(a); k != "" {
		return k
	}
	if k := pickFirstKey(b); k != "" {
		return k
	}

	// Fallback: gather key frequency across both sequences (older heuristic)
	freq := map[string]int{}
	addKeys := func(seq *yaml.Node) {
		if seq == nil || seq.Kind != yaml.SequenceNode {
			return
		}
		for _, item := range seq.Content {
			if item.Kind != yaml.MappingNode {
				continue
			}
			for i := 0; i < len(item.Content); i += 2 {
				k := item.Content[i]
				if k.Kind == yaml.ScalarNode {
					freq[k.Value]++
				}
			}
		}
	}
	addKeys(a)
	addKeys(b)

	preferred := []string{"name", "id", "key"}
	for _, p := range preferred {
		if freq[p] >= 1 {
			return p
		}
	}

	best := ""
	bestCount := 0
	for k, v := range freq {
		if v > bestCount {
			best = k
			bestCount = v
		}
	}
	return best
}

// mergeSequenceNodes handles both plain sequences (append) and keyed sequences (merge by key)
func mergeSequenceNodes(a, b *yaml.Node) *yaml.Node {
	// detect a key that can be used for keyed merging
	key := detectKeyForSequence(a, b)
	if key == "" {
		// plain append: keep a order then append b elements
		out := &yaml.Node{Kind: yaml.SequenceNode, Tag: "!!seq"}
		for _, n := range a.Content {
			out.Content = append(out.Content, deepCopyNode(n))
		}
		for _, n := range b.Content {
			out.Content = append(out.Content, deepCopyNode(n))
		}
		return out
	}

	// keyed merge: preserve order of a's elements, merging values when key matches; append new ones from b
	// build map from keyVal -> element for a, and keep order
	order := []string{}
	byKey := map[string]*yaml.Node{}

	for _, item := range a.Content {
		if item.Kind != yaml.MappingNode {
			// treat non-mapping elements by using their string representation as key
			k := item.ShortTag() + "-" + item.Value
			if _, ok := byKey[k]; !ok {
				order = append(order, k)
				byKey[k] = deepCopyNode(item)
			}
			continue
		}
		idx := findKeyIndex(item, key)
		if idx < 0 {
			// no key: use generated index
			k := fmt.Sprintf("__anon_%p", item)
			order = append(order, k)
			byKey[k] = deepCopyNode(item)
			continue
		}
		val := item.Content[idx+1]
		keyVal := val.Value
		if _, ok := byKey[keyVal]; !ok {
			order = append(order, keyVal)
			byKey[keyVal] = deepCopyNode(item)
		}
	}

	newItems := []*yaml.Node{}

	for _, item := range b.Content {
		if item.Kind != yaml.MappingNode {
			k := item.ShortTag() + "-" + item.Value
			if existing, ok := byKey[k]; ok {
				byKey[k] = mergeNodes(existing, item)
			} else {
				newItems = append(newItems, deepCopyNode(item))
			}
			continue
		}
		idx := findKeyIndex(item, key)
		if idx < 0 {
			newItems = append(newItems, deepCopyNode(item))
			continue
		}
		keyVal := item.Content[idx+1].Value
		if existing, ok := byKey[keyVal]; ok {
			byKey[keyVal] = mergeNodes(existing, item)
		} else {
			newItems = append(newItems, deepCopyNode(item))
		}
	}

	out := &yaml.Node{Kind: yaml.SequenceNode, Tag: "!!seq"}
	for _, k := range order {
		out.Content = append(out.Content, byKey[k])
	}
	for _, n := range newItems {
		out.Content = append(out.Content, n)
	}
	return out
}

func loadYAMLNode(path string) (*yaml.Node, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var node yaml.Node
	if err := yaml.Unmarshal(data, &node); err != nil {
		return nil, err
	}
	if len(node.Content) == 0 {
		return nil, fmt.Errorf("empty document in %s", path)
	}
	return node.Content[0], nil
}

func main() {
	if len(os.Args) < 3 {
		fmt.Fprintf(os.Stderr, "Usage: %s file1.yaml file2.yaml [file3.yaml ...]\n", os.Args[0])
		os.Exit(1)
	}

	files := os.Args[1:]
	docs := make([]*yaml.Node, 0, len(files))
	for _, f := range files {
		n, err := loadYAMLNode(f)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error loading %s: %v\n", f, err)
			os.Exit(1)
		}
		docs = append(docs, n)
	}

	// start from first
	result := deepCopyNode(docs[0])
	for _, next := range docs[1:] {
		result = mergeNodes(result, next)
	}

	// Emit as a single document
	doc := &yaml.Node{Kind: yaml.DocumentNode, Content: []*yaml.Node{result}}
	enc := yaml.NewEncoder(os.Stdout)
	enc.SetIndent(2)
	if err := enc.Encode(doc); err != nil {
		fmt.Fprintf(os.Stderr, "Error encoding merged YAML: %v\n", err)
		os.Exit(1)
	}
	enc.Close()
}
