package main

import (
	"bytes"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"sync"
	"time"
)

// relay is the loopback HTTP proxy the agent's MCP client talks to. It is the
// only holder of the Emisar API key: the bearer is injected upstream, so the
// agent process never sees it. Every tools/call is checked against the
// scenario's fail-closed allowlist BEFORE it reaches the portal.
type relay struct {
	server   *http.Server
	listener net.Listener
	upstream *url.URL
	apiKey   string
	token    string
	client   *http.Client
	recorder *recorder
}

func newRelay(portalURL, apiKey string, item scenario) (*relay, error) {
	upstream, err := localPortalURL(portalURL)
	if err != nil {
		return nil, err
	}
	// Loopback only: the headless agent runs on this host, and the
	// random-token endpoint must not be reachable from the network.
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return nil, err
	}
	tokenBytes := make([]byte, 24)
	if _, err := rand.Read(tokenBytes); err != nil {
		_ = listener.Close()
		return nil, err
	}
	r := &relay{
		listener: listener,
		upstream: upstream,
		apiKey:   apiKey,
		token:    base64.RawURLEncoding.EncodeToString(tokenBytes),
		client: &http.Client{
			Timeout:       70 * time.Second,
			CheckRedirect: func(_ *http.Request, _ []*http.Request) error { return http.ErrUseLastResponse },
		},
		recorder: newRecorder(item),
	}
	r.server = &http.Server{Handler: http.HandlerFunc(r.handle), ReadHeaderTimeout: 5 * time.Second}
	return r, nil
}

func localPortalURL(raw string) (*url.URL, error) {
	base, err := url.Parse(strings.TrimRight(raw, "/"))
	if err != nil {
		return nil, err
	}
	host := base.Hostname()
	ip := net.ParseIP(host)
	if base.Scheme != "http" || base.User != nil || base.RawQuery != "" || base.Fragment != "" || (host != "localhost" && (ip == nil || !ip.IsLoopback())) {
		return nil, errors.New("portal must be a loopback HTTP URL without credentials, query, or fragment")
	}
	if base.Path != "" && base.Path != "/" {
		return nil, errors.New("portal URL must not contain a path")
	}
	base.Path = "/api/mcp/rpc"
	return base, nil
}

func (r *relay) start() {
	go func() { _ = r.server.Serve(r.listener) }()
}

func (r *relay) close() error {
	return r.server.Close()
}

func (r *relay) endpoint() string {
	port := r.listener.Addr().(*net.TCPAddr).Port
	return fmt.Sprintf("http://127.0.0.1:%d/%s", port, r.token)
}

func (r *relay) handle(w http.ResponseWriter, request *http.Request) {
	if request.URL.Path != "/"+r.token {
		http.NotFound(w, request)
		return
	}
	requestBody, err := readBounded(request.Body, maxMCPFrameBytes)
	if err != nil {
		http.Error(w, "request too large", http.StatusRequestEntityTooLarge)
		return
	}
	requestMeta := r.recorder.request(requestBody)
	if requestMeta.blockCode != "" {
		responseBody := policyDeniedResponse(requestMeta.rpcID, requestMeta.blockCode)
		r.recorder.policyDenied(requestMeta, responseBody)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(responseBody)
		return
	}

	upstreamRequest, err := http.NewRequestWithContext(request.Context(), request.Method, r.upstream.String(), bytes.NewReader(requestBody))
	if err != nil {
		http.Error(w, "relay request failed", http.StatusBadGateway)
		return
	}
	copyMCPHeaders(upstreamRequest.Header, request.Header)
	upstreamRequest.Header.Set("Authorization", "Bearer "+r.apiKey)

	response, err := r.client.Do(upstreamRequest)
	if err != nil {
		r.recorder.transportError(requestMeta)
		http.Error(w, "upstream unavailable", http.StatusBadGateway)
		return
	}
	defer response.Body.Close()
	responseBody, err := readBounded(response.Body, maxMCPFrameBytes)
	if err != nil {
		r.recorder.transportError(requestMeta)
		http.Error(w, "upstream response too large", http.StatusBadGateway)
		return
	}
	r.recorder.response(requestMeta, responseBody, response.StatusCode)
	copyMCPHeaders(w.Header(), response.Header)
	w.WriteHeader(response.StatusCode)
	_, _ = w.Write(responseBody)
}

func readBounded(reader io.Reader, limit int64) ([]byte, error) {
	if reader == nil {
		return nil, nil
	}
	limited := io.LimitReader(reader, limit+1)
	body, err := io.ReadAll(limited)
	if err != nil {
		return nil, err
	}
	if int64(len(body)) > limit {
		return nil, fmt.Errorf("frame exceeds %d bytes", limit)
	}
	return body, nil
}

func copyMCPHeaders(dst, src http.Header) {
	for _, key := range []string{"Accept", "Content-Type", "Mcp-Protocol-Version", "Mcp-Session-Id"} {
		for _, value := range src.Values(key) {
			dst.Add(key, value)
		}
	}
}

// recorder keeps a bounded, metadata-only trace of every tools/call: names,
// digests, policy verdicts, receipt continuity, and run/operation states —
// never argument values, the bearer, or raw payloads.
type recorder struct {
	mu       sync.Mutex
	policy   scenario
	sequence int
	calls    []callRecord
	// receipts maps action_id+pack_ref of a successful get_action to the
	// contract_ref it returned; run_action must present a matching pair.
	receipts map[string]string
}

type requestMetadata struct {
	call      int
	rpcID     any
	blockCode string
}

func newRecorder(item scenario) *recorder {
	return &recorder{policy: item, receipts: map[string]string{}}
}

func (r *recorder) policyBlock(record callRecord, args map[string]any, encodedArgs []byte) string {
	if !stringSet(r.policy.AllowedTools)[record.Tool] {
		return "tool_not_allowed"
	}
	if record.Tool == "get_action" || record.Tool == "run_action" {
		if !stringSet(r.policy.AllowedActions)[record.ActionID] || record.PackRef == "" {
			return "action_not_allowed"
		}
	}
	if record.Tool != "run_action" {
		return ""
	}
	if !record.priorContractMatched {
		return "inspection_required"
	}
	if r.policy.RequireContractRef && !record.ContractRefMatched {
		return "contract_ref_required"
	}
	refs, ok := args["runner_refs"].([]any)
	if !ok || len(refs) == 0 || len(refs) > maxRunnerRefs || !uniqueStrings(refs) {
		return "runner_refs_out_of_bounds"
	}
	actionArgs, ok := args["args"].(map[string]any)
	if !ok {
		return "action_args_invalid"
	}
	encodedActionArgs, err := json.Marshal(actionArgs)
	if err != nil || len(encodedActionArgs) > maxActionArgsBytes || len(encodedArgs) > maxMCPFrameBytes {
		return "action_args_out_of_bounds"
	}
	return ""
}

func uniqueStrings(values []any) bool {
	seen := map[string]bool{}
	for _, value := range values {
		text, ok := value.(string)
		if !ok || text == "" || seen[text] {
			return false
		}
		seen[text] = true
	}
	return true
}

func (r *recorder) policyDenied(metadata requestMetadata, body []byte) {
	if metadata.call == 0 {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	index := metadata.call - 1
	if index < 0 || index >= len(r.calls) {
		return
	}
	call := &r.calls[index]
	call.ResponseError = true
	call.ResponseCode = metadata.blockCode
	call.ResponseBytes = len(body)
	call.CompletedAt = time.Now().UTC().Format(time.RFC3339Nano)
}

func policyDeniedResponse(id any, code string) []byte {
	payload := map[string]any{
		"jsonrpc": "2.0", "id": id,
		"result": map[string]any{
			"isError": true,
			"content": []any{map[string]any{"type": "text", "text": "The evaluator blocked a call outside the read-only scenario."}},
			"structuredContent": map[string]any{
				"ok": false, "error": map[string]any{"code": "evaluator_policy_denied", "kind": code},
			},
		},
	}
	body, _ := json.Marshal(payload)
	return body
}

func (r *recorder) request(body []byte) requestMetadata {
	var frame map[string]any
	if json.Unmarshal(body, &frame) != nil {
		return requestMetadata{}
	}
	if frame["method"] != "tools/call" {
		return requestMetadata{}
	}
	params, _ := frame["params"].(map[string]any)
	tool, _ := params["name"].(string)
	args, _ := params["arguments"].(map[string]any)
	encodedArgs, _ := json.Marshal(args)
	record := callRecord{
		Tool: tool, ArgumentKeys: boundedKeys(args),
		ArgumentsDigest: hashBytes(encodedArgs),
		ActionID:        stringValue(args["action_id"]), PackRef: stringValue(args["pack_ref"]),
		RunnerCount:        len(stringSlice(args["runner_refs"])),
		ContractRefPresent: stringValue(args["contract_ref"]) != "",
		StartedAt:          time.Now().UTC().Format(time.RFC3339Nano),
	}

	r.mu.Lock()
	if tool == "run_action" {
		expectedContract, found := r.receipts[record.ActionID+"\x00"+record.PackRef]
		record.priorContractMatched = found
		providedContract := stringValue(args["contract_ref"])
		record.ContractRefMatched = providedContract != "" && expectedContract != "" && providedContract == expectedContract
	}
	blockCode := r.policyBlock(record, args, encodedArgs)
	record.BlockedByPolicy = blockCode != ""
	r.sequence++
	record.Sequence = r.sequence
	r.calls = append(r.calls, record)
	index := len(r.calls) - 1
	r.mu.Unlock()
	return requestMetadata{call: index + 1, rpcID: frame["id"], blockCode: blockCode}
}

func (r *recorder) response(metadata requestMetadata, body []byte, statusCode int) {
	if metadata.call == 0 {
		return
	}
	payload := decodeMCPPayload(body)
	result, _ := payload["result"].(map[string]any)
	structured := structuredContent(result)

	r.mu.Lock()
	defer r.mu.Unlock()
	index := metadata.call - 1
	if index < 0 || index >= len(r.calls) {
		return
	}
	call := &r.calls[index]
	call.ResponseBytes = len(body)
	call.CompletedAt = time.Now().UTC().Format(time.RFC3339Nano)
	call.ResponseError = statusCode >= 400 || boolValue(result["isError"]) || payload["error"] != nil
	call.ResponseCode = nestedString(structured, "error", "code")
	call.RunStates = collectRunStates(call.Tool, structured)
	if call.Tool == "run_action" && !call.ResponseError {
		operationID := stringValue(structured["operation_id"])
		if !runOperationIDsMatch(operationID, call.RunStates) {
			call.ResponseError = true
			call.ResponseCode = "operation_id_mismatch"
		}
	}
	if call.Tool == "get_action" && !call.ResponseError && call.ActionID != "" && call.PackRef != "" {
		r.receipts[call.ActionID+"\x00"+call.PackRef] = stringValue(structured["contract_ref"])
	}
}

func (r *recorder) transportError(metadata requestMetadata) {
	if metadata.call == 0 {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	index := metadata.call - 1
	if index >= 0 && index < len(r.calls) {
		r.calls[index].ResponseError = true
		r.calls[index].ResponseCode = "transport_error"
		r.calls[index].CompletedAt = time.Now().UTC().Format(time.RFC3339Nano)
	}
}

func (r *recorder) snapshot() []callRecord {
	r.mu.Lock()
	defer r.mu.Unlock()
	calls := make([]callRecord, len(r.calls))
	copy(calls, r.calls)
	return calls
}

func decodeMCPPayload(body []byte) map[string]any {
	var payload map[string]any
	if json.Unmarshal(body, &payload) == nil {
		return payload
	}
	for _, line := range strings.Split(string(body), "\n") {
		if strings.HasPrefix(line, "data:") && json.Unmarshal([]byte(strings.TrimSpace(strings.TrimPrefix(line, "data:"))), &payload) == nil {
			return payload
		}
	}
	return map[string]any{}
}

func structuredContent(result map[string]any) map[string]any {
	if content, ok := result["structuredContent"].(map[string]any); ok {
		return content
	}
	items, _ := result["content"].([]any)
	if len(items) == 0 {
		return map[string]any{}
	}
	item, _ := items[0].(map[string]any)
	text, _ := item["text"].(string)
	var content map[string]any
	if json.Unmarshal([]byte(text), &content) == nil {
		return content
	}
	return map[string]any{}
}

// collectRunStates extracts run identity and status from the shapes that carry
// them: run_action and recent_runs return `runs`, wait_for_run returns `run`.
func collectRunStates(tool string, structured map[string]any) []runState {
	objects := make([]map[string]any, 0)
	switch tool {
	case "run_action", "recent_runs":
		for _, value := range sliceValue(structured["runs"]) {
			if object, ok := value.(map[string]any); ok {
				objects = append(objects, object)
			}
		}
	case "wait_for_run":
		if object, ok := structured["run"].(map[string]any); ok {
			objects = append(objects, object)
		}
	}
	states := make([]runState, 0, len(objects))
	for _, object := range objects {
		runID := stringValue(object["run_id"])
		operationID := stringValue(object["operation_id"])
		status := stringValue(object["status"])
		if runID == "" || operationID == "" || status == "" {
			continue
		}
		runnerName, _, _ := strings.Cut(stringValue(object["runner_ref"]), "~")
		states = append(states, runState{
			RunID: runID, OperationID: operationID, Status: status,
			RunURL: stringValue(object["run_url"]), RunnerName: runnerName,
		})
	}
	sort.Slice(states, func(i, j int) bool {
		if states[i].RunID == states[j].RunID {
			return states[i].Status < states[j].Status
		}
		return states[i].RunID < states[j].RunID
	})
	return states
}

func runOperationIDsMatch(operationID string, states []runState) bool {
	if operationID == "" || len(states) == 0 {
		return false
	}
	for _, state := range states {
		if state.OperationID != operationID {
			return false
		}
	}
	return true
}

func hashBytes(value []byte) string {
	sum := sha256.Sum256(value)
	return "sha256:" + hex.EncodeToString(sum[:])
}

func boundedKeys(value map[string]any) []string {
	keys := make([]string, 0, min(len(value), 33))
	for key := range value {
		keys = append(keys, safeKey(key))
	}
	sort.Strings(keys)
	if len(keys) > 32 {
		keys = append(keys[:32], "<overflow>")
	}
	return keys
}

func safeKey(value string) string {
	if value == "" || len(value) > 64 {
		return "<invalid>"
	}
	for _, char := range value {
		if (char < 'a' || char > 'z') && (char < 'A' || char > 'Z') && (char < '0' || char > '9') && char != '_' && char != '-' && char != '.' {
			return "<invalid>"
		}
	}
	return value
}

func stringValue(value any) string {
	text, _ := value.(string)
	return text
}

func boolValue(value any) bool {
	flag, _ := value.(bool)
	return flag
}

func stringSlice(value any) []string {
	items, _ := value.([]any)
	out := make([]string, 0, len(items))
	for _, item := range items {
		if text, ok := item.(string); ok {
			out = append(out, text)
		}
	}
	return out
}

func sliceValue(value any) []any {
	items, _ := value.([]any)
	return items
}

func nestedString(value map[string]any, path ...string) string {
	var current any = value
	for _, key := range path {
		object, ok := current.(map[string]any)
		if !ok {
			return ""
		}
		current = object[key]
	}
	return stringValue(current)
}
