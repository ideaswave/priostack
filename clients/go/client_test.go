package priostack

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
)

// capture records the decoded JSON-RPC request each call made, keyed by tool
// name, so a test can assert exactly which arguments went over the wire.
type capture struct {
	mu    sync.Mutex
	calls []rpcRequest
}

func (c *capture) add(r rpcRequest) {
	c.mu.Lock()
	c.calls = append(c.calls, r)
	c.mu.Unlock()
}

func (c *capture) byMethod(name string) (rpcRequest, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	for _, r := range c.calls {
		if r.Params.Name == name {
			return r, true
		}
	}
	return rpcRequest{}, false
}

// envelopeServer wraps a per-tool response map in the full MCP/JSON-RPC shape.
func envelopeServer(t *testing.T, cap *capture, envelopes map[string]string) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		var req rpcRequest
		if err := json.Unmarshal(body, &req); err != nil {
			t.Errorf("server got non-JSON request: %v", err)
		}
		if got := r.Header.Get("Accept"); got != "application/json" {
			t.Errorf("Accept header = %q, want application/json", got)
		}
		cap.add(req)
		env, ok := envelopes[req.Params.Name]
		if !ok {
			http.Error(w, "unknown tool", http.StatusNotFound)
			return
		}
		resp := map[string]any{
			"jsonrpc": "2.0",
			"id":      req.ID,
			"result": map[string]any{
				"content": []map[string]any{{"type": "text", "text": env}},
				"isError": false,
			},
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(resp)
	}))
}

func TestConnectCapturesPascalCaseSessionID(t *testing.T) {
	cap := &capture{}
	srv := envelopeServer(t, cap, map[string]string{
		"noetic.connect": `{"ok":true,"outcome":"connected","data":{"SessionID":"sess-123","ResolvedAccount":"acct-9","GrantedCapabilities":["mutate"],"BoundSpace":"space-1","ResolvedMaxTokens":8192}}`,
	})
	defer srv.Close()

	c := New(WithEndpoint(srv.URL), WithToken("tok-abc"))
	res, err := c.Connect("", 0)
	if err != nil {
		t.Fatalf("Connect: %v", err)
	}
	if res.SessionID != "sess-123" {
		t.Fatalf("SessionID = %q, want sess-123", res.SessionID)
	}
	if c.SessionID() != "sess-123" {
		t.Fatalf("client.SessionID() = %q, want sess-123 (must be captured)", c.SessionID())
	}
	if res.ResolvedMaxTokens != 8192 || res.ResolvedAccount != "acct-9" {
		t.Fatalf("unexpected connect fields: %+v", res)
	}
	req, _ := cap.byMethod("noetic.connect")
	if req.Params.Arguments["token"] != "tok-abc" {
		t.Fatalf("connect token arg = %v, want tok-abc", req.Params.Arguments["token"])
	}
	if req.Params.Arguments["maxResponseTokens"] != float64(4096) {
		t.Fatalf("connect maxResponseTokens = %v, want 4096 default", req.Params.Arguments["maxResponseTokens"])
	}
}

func TestStoreUsesSpaceArgAndValidatesKind(t *testing.T) {
	cap := &capture{}
	srv := envelopeServer(t, cap, map[string]string{
		"noetic.connect": `{"ok":true,"data":{"SessionID":"s1"}}`,
		"noetic.store":   `{"ok":true,"data":{"objectRefs":[{"objectRef":"o1"},{"objectRef":"o2"}]}}`,
	})
	defer srv.Close()

	c := New(WithEndpoint(srv.URL), WithToken("t"))
	if _, err := c.Connect("", 0); err != nil {
		t.Fatalf("Connect: %v", err)
	}
	res, err := c.Store("space-42", []StoreObject{
		{Content: "a rule", Type: "declaration"},
		{Content: "a fact"}, // empty type must default to declaration
	})
	if err != nil {
		t.Fatalf("Store: %v", err)
	}
	if res.Count() != 2 {
		t.Fatalf("Count = %d, want 2", res.Count())
	}
	req, ok := cap.byMethod("noetic.store")
	if !ok {
		t.Fatal("store was not called")
	}
	if req.Params.Arguments["space"] != "space-42" {
		t.Fatalf("store must send arg key 'space' = space-42, got %v", req.Params.Arguments["space"])
	}
	if _, hasSpaceID := req.Params.Arguments["spaceId"]; hasSpaceID {
		t.Fatal("store must NOT send 'spaceId'")
	}

	// invalid kind is rejected client-side, before any network call
	if _, err := c.Store("space-42", []StoreObject{{Content: "x", Type: "inference"}}); err == nil {
		t.Fatal("Store with invalid kind should error")
	}
}

func TestGrantUsesResourceArg(t *testing.T) {
	cap := &capture{}
	srv := envelopeServer(t, cap, map[string]string{
		"noetic.connect": `{"ok":true,"data":{"SessionID":"s1"}}`,
		"noetic.grant":   `{"ok":true,"data":{"capabilityRef":"cap-1","subject":"agent-b","resource":"space-1","effectiveRights":["read","quote"]}}`,
	})
	defer srv.Close()

	c := New(WithEndpoint(srv.URL), WithToken("t"))
	if _, err := c.Connect("", 0); err != nil {
		t.Fatalf("Connect: %v", err)
	}
	res, err := c.GrantAccess("space-1", "agent-b", nil)
	if err != nil {
		t.Fatalf("GrantAccess: %v", err)
	}
	if res.CapabilityRef != "cap-1" {
		t.Fatalf("CapabilityRef = %q, want cap-1", res.CapabilityRef)
	}
	req, _ := cap.byMethod("noetic.grant")
	if req.Params.Arguments["resource"] != "space-1" {
		t.Fatalf("grant must send arg key 'resource' = space-1, got %v", req.Params.Arguments["resource"])
	}
	if req.Params.Arguments["subjectPrincipal"] != "agent-b" {
		t.Fatalf("grant subjectPrincipal = %v, want agent-b", req.Params.Arguments["subjectPrincipal"])
	}
	rights, _ := req.Params.Arguments["rights"].([]any)
	if len(rights) != 2 || rights[0] != "read" || rights[1] != "quote" {
		t.Fatalf("grant default rights = %v, want [read quote]", req.Params.Arguments["rights"])
	}
}

func TestRequestAccessUsesRightsArg(t *testing.T) {
	cap := &capture{}
	srv := envelopeServer(t, cap, map[string]string{
		"noetic.connect":        `{"ok":true,"data":{"SessionID":"s1"}}`,
		"noetic.request_access": `{"ok":true,"data":{"requestId":"req-1"}}`,
	})
	defer srv.Close()

	c := New(WithEndpoint(srv.URL), WithToken("t"))
	if _, err := c.Connect("", 0); err != nil {
		t.Fatalf("Connect: %v", err)
	}
	if _, err := c.RequestAccess("space-9", []string{"read"}, nil); err != nil {
		t.Fatalf("RequestAccess: %v", err)
	}
	req, _ := cap.byMethod("noetic.request_access")
	if _, has := req.Params.Arguments["rights"]; !has {
		t.Fatal("request_access must send arg key 'rights'")
	}
	if _, bad := req.Params.Arguments["requestedRights"]; bad {
		t.Fatal("request_access must NOT send 'requestedRights'")
	}
}

func TestToolErrorMapsToSentinel(t *testing.T) {
	srv := envelopeServer(t, &capture{}, map[string]string{
		"noetic.connect": `{"ok":true,"data":{"SessionID":"s1"}}`,
		"noetic.store":   `{"ok":false,"outcome":"capability-denied","detail":"missing mutate"}`,
	})
	defer srv.Close()

	c := New(WithEndpoint(srv.URL), WithToken("t"))
	if _, err := c.Connect("", 0); err != nil {
		t.Fatalf("Connect: %v", err)
	}
	_, err := c.Store("space-1", []StoreObject{{Content: "x", Type: "declaration"}})
	if err == nil {
		t.Fatal("expected a tool error")
	}
	if !errors.Is(err, ErrCapabilityDenied) {
		t.Fatalf("errors.Is(err, ErrCapabilityDenied) = false; err = %v", err)
	}
	te, ok := AsToolError(err)
	if !ok {
		t.Fatalf("AsToolError returned false for %v", err)
	}
	if te.Outcome != OutcomeCapabilityDenied || te.Detail != "missing mutate" {
		t.Fatalf("tool error fields = %+v", te)
	}
	var acnErr Error
	if !errors.As(err, &acnErr) {
		t.Fatal("tool error should satisfy the Error interface")
	}
}

func TestHTTPErrorIsTransportError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "boom", http.StatusInternalServerError)
	}))
	defer srv.Close()

	c := New(WithEndpoint(srv.URL))
	_, err := c.Discover("", 0)
	if err == nil {
		t.Fatal("expected a transport error")
	}
	var te *TransportError
	if !errors.As(err, &te) {
		t.Fatalf("want *TransportError, got %T: %v", err, err)
	}
	if te.HTTPStatus != http.StatusInternalServerError {
		t.Fatalf("HTTPStatus = %d, want 500", te.HTTPStatus)
	}
}

func TestJSONRPCIDIncrements(t *testing.T) {
	cap := &capture{}
	srv := envelopeServer(t, cap, map[string]string{
		"noetic.discover": `{"ok":true,"data":{"spaces":[]}}`,
	})
	defer srv.Close()

	c := New(WithEndpoint(srv.URL))
	for i := 0; i < 3; i++ {
		if _, err := c.Discover("", 0); err != nil {
			t.Fatalf("Discover %d: %v", i, err)
		}
	}
	cap.mu.Lock()
	defer cap.mu.Unlock()
	if len(cap.calls) != 3 {
		t.Fatalf("got %d calls, want 3", len(cap.calls))
	}
	for i, want := range []int64{1, 2, 3} {
		if cap.calls[i].ID != want {
			t.Fatalf("call %d id = %d, want %d", i, cap.calls[i].ID, want)
		}
	}
}

func TestSessionRequiredBeforeStore(t *testing.T) {
	c := New(WithEndpoint("http://127.0.0.1:0"))
	_, err := c.Store("space-1", []StoreObject{{Content: "x"}})
	if err == nil {
		t.Fatal("Store without a session should error")
	}
	var te *TransportError
	if !errors.As(err, &te) {
		t.Fatalf("want *TransportError, got %T", err)
	}
}
