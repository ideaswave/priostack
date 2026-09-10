package priostack

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// Version is the client version, reported in the User-Agent header.
const Version = "0.2.0"

// DefaultEndpoint is the canonical Streamable-HTTP MCP endpoint. The legacy
// https://priostack.com/acn/rpc path is an accepted alias.
const DefaultEndpoint = "https://priostack.com/mcp"

const (
	defaultTimeout    = 30 * time.Second
	defaultMaxRetries = 2
	defaultBackoff    = 500 * time.Millisecond
	maxBackoff        = 10 * time.Second
	userAgent         = "priostack-go/" + Version
)

// Client is a JSON-RPC client for the Priostack ACN. Construct one with [New].
// A Client reuses a single *http.Client and is safe for concurrent use by
// multiple goroutines once a session has been established.
type Client struct {
	endpoint   string
	http       *http.Client
	timeout    time.Duration
	maxRetries int
	backoff    time.Duration

	idc atomic.Int64

	mu        sync.Mutex
	token     string
	sessionID string
}

// Option configures a [Client] built by [New].
type Option func(*Client)

// WithEndpoint overrides the RPC endpoint (default [DefaultEndpoint]).
func WithEndpoint(endpoint string) Option {
	return func(c *Client) {
		if endpoint != "" {
			c.endpoint = endpoint
		}
	}
}

// WithToken seeds a previously issued bearer token so an existing agent can
// reconnect without registering again.
func WithToken(token string) Option {
	return func(c *Client) { c.token = token }
}

// WithTimeout sets the per-request timeout (default 30s). Ignored when a custom
// *http.Client is supplied with [WithHTTPClient] (set the timeout on it).
func WithTimeout(d time.Duration) Option {
	return func(c *Client) {
		if d > 0 {
			c.timeout = d
		}
	}
}

// WithHTTPClient injects a pre-built *http.Client (custom transport, proxy, or
// TLS settings). Its own Timeout is respected as-is.
func WithHTTPClient(h *http.Client) Option {
	return func(c *Client) {
		if h != nil {
			c.http = h
		}
	}
}

// WithMaxRetries sets how many times a back-pressure response (HTTP 429/503) is
// retried before failing (default 2). Only those explicit back-pressure
// statuses are retried; network faults and read timeouts are never retried, so
// a non-idempotent call such as Store is never silently duplicated.
func WithMaxRetries(n int) Option {
	return func(c *Client) {
		if n >= 0 {
			c.maxRetries = n
		}
	}
}

// WithBackoff sets the exponential backoff base between retries (default 500ms).
func WithBackoff(d time.Duration) Option {
	return func(c *Client) {
		if d >= 0 {
			c.backoff = d
		}
	}
}

// New builds a Client. With no options it targets [DefaultEndpoint] with a 30s
// timeout.
func New(opts ...Option) *Client {
	c := &Client{
		endpoint:   DefaultEndpoint,
		timeout:    defaultTimeout,
		maxRetries: defaultMaxRetries,
		backoff:    defaultBackoff,
	}
	for _, o := range opts {
		o(c)
	}
	if c.http == nil {
		c.http = &http.Client{Timeout: c.timeout}
	}
	return c
}

// Token returns the bearer token currently held by the client (set by
// [Client.Register], [Client.Connect], [Client.RotateToken], or [WithToken]).
func (c *Client) Token() string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.token
}

// SessionID returns the active session id, or "" when not connected.
func (c *Client) SessionID() string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.sessionID
}

// Connected reports whether a session id has been captured.
func (c *Client) Connected() bool { return c.SessionID() != "" }

func (c *Client) setToken(t string) {
	c.mu.Lock()
	c.token = t
	c.mu.Unlock()
}

func (c *Client) setSession(s string) {
	c.mu.Lock()
	c.sessionID = s
	c.mu.Unlock()
}

func (c *Client) requireSession() (string, error) {
	if s := c.SessionID(); s != "" {
		return s, nil
	}
	return "", &TransportError{Message: "no active session: call Connect first"}
}

func (c *Client) nextID() int64 { return c.idc.Add(1) }

// Close best-effort disconnects an active session and releases idle
// connections. It never returns an error and satisfies io.Closer.
func (c *Client) Close() error {
	if c.Connected() {
		_, _ = c.Disconnect()
	}
	c.http.CloseIdleConnections()
	return nil
}

// --------------------------------------------------------------------------- //
// Transport
// --------------------------------------------------------------------------- //

type rpcRequest struct {
	JSONRPC string    `json:"jsonrpc"`
	ID      int64     `json:"id"`
	Method  string    `json:"method"`
	Params  rpcParams `json:"params"`
}

type rpcParams struct {
	Name      string         `json:"name"`
	Arguments map[string]any `json:"arguments"`
}

type rpcResponse struct {
	JSONRPC string     `json:"jsonrpc"`
	Result  *rpcResult `json:"result"`
	Error   *rpcError  `json:"error"`
}

type rpcResult struct {
	Content []rpcContent `json:"content"`
	IsError bool         `json:"isError"`
}

type rpcContent struct {
	Type string `json:"type"`
	Text string `json:"text"`
}

type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

// envelope is the tool result carried as a JSON string in result.content[0].text.
type envelope struct {
	OK      bool            `json:"ok"`
	Outcome string          `json:"outcome"`
	Data    json.RawMessage `json:"data"`
	Detail  string          `json:"detail"`
	Receipt json.RawMessage `json:"receipt"`
}

// Call invokes any noetic.* tool and returns its unwrapped data payload as a
// map. This is the low-level escape hatch behind every typed method — use it
// for tools this client does not wrap explicitly. When the tool's data payload
// is not a JSON object it is returned wrapped under the "data" key.
func (c *Client) Call(method string, arguments map[string]any) (map[string]any, error) {
	data, err := c.do(method, arguments)
	if err != nil {
		return nil, err
	}
	return dataAsMap(data), nil
}

// do performs the full JSON-RPC round trip and returns the envelope's raw data
// payload, or a typed error. It is the single transport core shared by Call and
// every typed method.
func (c *Client) do(method string, args map[string]any) (json.RawMessage, error) {
	if args == nil {
		args = map[string]any{}
	}
	payload, err := json.Marshal(rpcRequest{
		JSONRPC: "2.0",
		ID:      c.nextID(),
		Method:  "tools/call",
		Params:  rpcParams{Name: method, Arguments: args},
	})
	if err != nil {
		return nil, &TransportError{Message: fmt.Sprintf("could not encode request for %s: %v", method, err), Method: method}
	}

	var body []byte
	var status int
	for attempt := 0; ; attempt++ {
		req, err := http.NewRequest(http.MethodPost, c.endpoint, bytes.NewReader(payload))
		if err != nil {
			return nil, &TransportError{Message: fmt.Sprintf("could not build request for %s: %v", method, err), Method: method}
		}
		req.Header.Set("Content-Type", "application/json")
		// Ask for a plain JSON reply; the Streamable-HTTP endpoint would
		// otherwise be free to answer a POST as a one-shot SSE frame.
		req.Header.Set("Accept", "application/json")
		req.Header.Set("User-Agent", userAgent)

		resp, err := c.http.Do(req)
		if err != nil {
			// A network fault: never retried, so a Store the server may
			// already have applied is not silently resent.
			return nil, &TransportError{Message: fmt.Sprintf("network error calling %s: %v", method, err), Method: method}
		}
		b, readErr := io.ReadAll(resp.Body)
		resp.Body.Close()
		status = resp.StatusCode

		if isBackpressure(status) && attempt < c.maxRetries {
			// Back-pressure is signalled before the server does work, so
			// re-sending the identical request is safe.
			time.Sleep(backoffDelay(c.backoff, attempt, resp.Header.Get("Retry-After")))
			continue
		}
		if readErr != nil {
			return nil, &TransportError{Message: fmt.Sprintf("could not read response calling %s: %v", method, readErr), Method: method}
		}
		body = b
		break
	}

	if status >= 400 {
		return nil, &TransportError{
			Message:    fmt.Sprintf("HTTP %d calling %s: %s", status, method, snippet(body, 500)),
			Method:     method,
			HTTPStatus: status,
		}
	}

	var rpc rpcResponse
	if err := json.Unmarshal(body, &rpc); err != nil {
		return nil, &TransportError{Message: fmt.Sprintf("non-JSON response calling %s: %s", method, snippet(body, 500)), Method: method}
	}
	if rpc.Error != nil {
		return nil, &TransportError{
			Message: fmt.Sprintf("JSON-RPC error calling %s: %s", method, rpc.Error.Message),
			Method:  method,
			Code:    rpc.Error.Code,
		}
	}
	if rpc.Result == nil {
		return nil, &TransportError{Message: fmt.Sprintf("malformed response calling %s: %s", method, snippet(body, 500)), Method: method}
	}

	env, err := unwrap(rpc.Result, method)
	if err != nil {
		return nil, err
	}
	if !env.OK {
		return nil, toolErrorFor(env.Outcome, env.Detail, method, env.Data)
	}
	return env.Data, nil
}

func unwrap(result *rpcResult, method string) (envelope, error) {
	var env envelope
	if len(result.Content) == 0 {
		return env, &TransportError{Message: fmt.Sprintf("response for %s had no content block", method), Method: method}
	}
	text := result.Content[0].Text
	if text == "" {
		return env, &TransportError{Message: fmt.Sprintf("response for %s had no text payload", method), Method: method}
	}
	if err := json.Unmarshal([]byte(text), &env); err != nil {
		return env, &TransportError{Message: fmt.Sprintf("could not decode envelope for %s: %s", method, snippet([]byte(text), 300)), Method: method}
	}
	return env, nil
}

func isBackpressure(status int) bool { return status == 429 || status == 503 }

func backoffDelay(base time.Duration, attempt int, retryAfter string) time.Duration {
	if retryAfter != "" {
		if secs, err := strconv.Atoi(strings.TrimSpace(retryAfter)); err == nil && secs >= 0 {
			d := time.Duration(secs) * time.Second
			if d > maxBackoff {
				d = maxBackoff
			}
			return d
		}
	}
	d := base * time.Duration(1<<uint(attempt))
	if d > maxBackoff {
		d = maxBackoff
	}
	return d
}

func snippet(b []byte, n int) string {
	s := string(b)
	if len(s) > n {
		return s[:n]
	}
	return s
}

// dataAsMap renders an envelope's data payload as a map. A JSON object is
// returned as-is; anything else (array, scalar, or absent/null) is wrapped
// under the "data" key, mirroring the Python client.
func dataAsMap(data json.RawMessage) map[string]any {
	if len(data) == 0 || string(data) == "null" {
		return map[string]any{"data": nil}
	}
	var m map[string]any
	if err := json.Unmarshal(data, &m); err == nil {
		return m
	}
	var v any
	_ = json.Unmarshal(data, &v)
	return map[string]any{"data": v}
}

// decodeInto unmarshals the envelope data payload into v and also returns it as
// a map for a result's Raw field.
func decodeInto(data json.RawMessage, method string, v any) (map[string]any, error) {
	raw := data
	if len(raw) == 0 {
		raw = json.RawMessage("null")
	}
	if err := json.Unmarshal(raw, v); err != nil {
		return nil, &TransportError{Message: fmt.Sprintf("could not decode result for %s: %v", method, err), Method: method}
	}
	return dataAsMap(data), nil
}

// --------------------------------------------------------------------------- //
// Identity
// --------------------------------------------------------------------------- //

// Register self-registers a new agent and captures its bearer token.
//
// Only available on the online multi-agent ACN. The token is shown once; it is
// stored on the client and returned so it can be persisted for future sessions.
// Returns a [ToolError] matching [ErrNotSupported] on a single-tenant ACN that
// does not offer self-registration. An empty displayName defaults to "agent".
func (c *Client) Register(displayName string) (*RegisterResult, error) {
	if displayName == "" {
		displayName = "agent"
	}
	data, err := c.do("noetic.register", map[string]any{"displayName": displayName})
	if err != nil {
		return nil, err
	}
	var r RegisterResult
	raw, err := decodeInto(data, "noetic.register", &r)
	if err != nil {
		return nil, err
	}
	r.Raw = raw
	if r.Token == "" {
		return nil, &TransportError{Message: fmt.Sprintf("register returned no token: %s", string(data)), Method: "noetic.register"}
	}
	c.setToken(r.Token)
	return &r, nil
}

// Connect opens a session with a bearer token and captures the session id.
//
// Pass token explicitly, or "" to use the token captured by [Client.Register]
// or seeded via [WithToken]. maxTokens caps a response's token budget; pass 0
// for the default (4096). Re-call Connect after being granted access to a space
// so the widened scope is applied.
func (c *Client) Connect(token string, maxTokens int) (*ConnectResult, error) {
	tok := token
	if tok == "" {
		tok = c.Token()
	}
	if tok == "" {
		return nil, &TransportError{Message: "Connect needs a token: Register first or pass one"}
	}
	if maxTokens <= 0 {
		maxTokens = 4096
	}
	data, err := c.do("noetic.connect", map[string]any{"token": tok, "maxResponseTokens": maxTokens})
	if err != nil {
		return nil, err
	}
	var r ConnectResult
	raw, err := decodeInto(data, "noetic.connect", &r)
	if err != nil {
		return nil, err
	}
	r.Raw = raw
	if r.SessionID == "" {
		return nil, &TransportError{Message: fmt.Sprintf("connect returned no SessionID: %s", string(data)), Method: "noetic.connect"}
	}
	c.setSession(r.SessionID)
	c.setToken(tok)
	return &r, nil
}

// Disconnect ends the current session. Durable facts are not revoked.
func (c *Client) Disconnect() (map[string]any, error) {
	sid, err := c.requireSession()
	if err != nil {
		return nil, err
	}
	data, err := c.do("noetic.disconnect", map[string]any{"sessionId": sid})
	if err != nil {
		return nil, err
	}
	c.setSession("")
	return dataAsMap(data), nil
}

// RotateToken mints a fresh bearer token for this agent and retires the old
// one. Existing sessions keep working; the new token is stored on the client
// and returned for future Connect calls.
func (c *Client) RotateToken() (string, error) {
	sid, err := c.requireSession()
	if err != nil {
		return "", err
	}
	data, err := c.do("noetic.rotate_token", map[string]any{"sessionId": sid})
	if err != nil {
		return "", err
	}
	var wrap struct {
		Token string `json:"token"`
	}
	_ = json.Unmarshal(data, &wrap)
	if wrap.Token == "" {
		return "", &TransportError{Message: "rotate_token returned no token", Method: "noetic.rotate_token"}
	}
	c.setToken(wrap.Token)
	return wrap.Token, nil
}

// Capabilities discovers the grantable rights and world-mutation vocabulary in
// scope for the session.
func (c *Client) Capabilities() (map[string]any, error) {
	sid, err := c.requireSession()
	if err != nil {
		return nil, err
	}
	data, err := c.do("noetic.capabilities", map[string]any{"sessionId": sid})
	if err != nil {
		return nil, err
	}
	return dataAsMap(data), nil
}

// --------------------------------------------------------------------------- //
// Spaces + facts
// --------------------------------------------------------------------------- //

// CreateSpace creates an isolated context space and returns its resolved id.
// Use the returned SpaceID for writes. Pass nil opts for defaults.
func (c *Client) CreateSpace(displayName string, opts *CreateSpaceOptions) (*SpaceResult, error) {
	sid, err := c.requireSession()
	if err != nil {
		return nil, err
	}
	args := map[string]any{"sessionId": sid, "displayName": displayName}
	if opts != nil {
		if len(opts.DefaultRights) > 0 {
			args["defaultRights"] = opts.DefaultRights
		}
		if opts.Visibility != "" {
			args["visibility"] = opts.Visibility
		}
		if opts.PersistenceMode != "" {
			args["persistenceMode"] = opts.PersistenceMode
		}
		if opts.ProtectionLevel != "" {
			args["protectionLevel"] = opts.ProtectionLevel
		}
	}
	data, err := c.do("noetic.create_space", args)
	if err != nil {
		return nil, err
	}
	var r SpaceResult
	raw, err := decodeInto(data, "noetic.create_space", &r)
	if err != nil {
		return nil, err
	}
	r.Raw = raw
	if r.SpaceID == "" {
		return nil, &TransportError{Message: fmt.Sprintf("create_space returned no spaceId: %s", string(data)), Method: "noetic.create_space"}
	}
	return &r, nil
}

// Store persists typed facts into a space. Each object's Content is required
// and its Type must be one of [StoreKinds] (empty defaults to "declaration").
// Writing needs the write right and the mutate capability; the space owner has
// both. The spaceID is sent under the "space" argument.
func (c *Client) Store(spaceID string, objects []StoreObject) (*StoreResult, error) {
	sid, err := c.requireSession()
	if err != nil {
		return nil, err
	}
	norm := make([]StoreObject, 0, len(objects))
	for i, o := range objects {
		if o.Content == "" {
			return nil, fmt.Errorf("priostack: object %d needs a non-empty Content field", i)
		}
		kind := o.Type
		if kind == "" {
			kind = "declaration"
		}
		if !validStoreKind(kind) {
			return nil, fmt.Errorf("priostack: invalid object type %q; must be one of %v", kind, StoreKinds)
		}
		norm = append(norm, StoreObject{Content: o.Content, Type: kind, Provenance: o.Provenance})
	}
	data, err := c.do("noetic.store", map[string]any{"sessionId": sid, "space": spaceID, "objects": norm})
	if err != nil {
		return nil, err
	}
	var r StoreResult
	raw, err := decodeInto(data, "noetic.store", &r)
	if err != nil {
		return nil, err
	}
	r.Raw = raw
	return &r, nil
}

// Fetch reads stored objects back from a space (this is the content reader).
//
// query is a case-insensitive substring filter over content — not semantic
// search; pass "" for no filter. limit caps the count (0 = server default).
// This is distinct from noetic.query, a geometric divergence probe. The spaceID
// is sent under the "space" argument.
func (c *Client) Fetch(spaceID, query string, limit int) (*FetchResult, error) {
	sid, err := c.requireSession()
	if err != nil {
		return nil, err
	}
	args := map[string]any{"sessionId": sid, "space": spaceID}
	if query != "" {
		args["query"] = query
	}
	if limit > 0 {
		args["limit"] = limit
	}
	data, err := c.do("noetic.fetch", args)
	if err != nil {
		return nil, err
	}
	var r FetchResult
	raw, err := decodeInto(data, "noetic.fetch", &r)
	if err != nil {
		return nil, err
	}
	r.Raw = raw
	if r.Space == "" {
		r.Space = spaceID
	}
	return &r, nil
}

// --------------------------------------------------------------------------- //
// Sharing
// --------------------------------------------------------------------------- //

// GrantAccess grants another agent scoped access to a space you own.
//
// subjectPrincipal is the grantee's agentId. Pass nil opts to grant the default
// rights (read, quote). The space is sent under the "resource" argument (its
// canonical name on the server).
func (c *Client) GrantAccess(spaceID, subjectPrincipal string, opts *GrantOptions) (*GrantResult, error) {
	sid, err := c.requireSession()
	if err != nil {
		return nil, err
	}
	rights := []string{"read", "quote"}
	var worldMutation, persistence string
	if opts != nil {
		if len(opts.Rights) > 0 {
			rights = opts.Rights
		}
		worldMutation = opts.WorldMutation
		persistence = opts.PersistenceMode
	}
	args := map[string]any{
		"sessionId":        sid,
		"subjectPrincipal": subjectPrincipal,
		// The server names the space argument "resource".
		"resource": spaceID,
		// "space" is sent too as a harmless alias for older builds; unknown
		// fields are ignored server-side.
		"space":  spaceID,
		"rights": rights,
	}
	if worldMutation != "" {
		args["worldMutation"] = worldMutation
	}
	if persistence != "" {
		args["persistenceMode"] = persistence
	}
	data, err := c.do("noetic.grant", args)
	if err != nil {
		return nil, err
	}
	return grantResult(data, "noetic.grant")
}

// RevokeAccess revokes a previously granted capability (immediate, forward-only).
func (c *Client) RevokeAccess(capabilityRef string) (map[string]any, error) {
	sid, err := c.requireSession()
	if err != nil {
		return nil, err
	}
	data, err := c.do("noetic.revoke", map[string]any{"sessionId": sid, "capabilityRef": capabilityRef})
	if err != nil {
		return nil, err
	}
	return dataAsMap(data), nil
}

// RequestAccess asks the owner of a remote space for scoped access (consumer
// side). The requested rights are sent under the "rights" argument. Pass nil
// opts for none.
func (c *Client) RequestAccess(spaceID string, rights []string, opts *RequestAccessOptions) (map[string]any, error) {
	sid, err := c.requireSession()
	if err != nil {
		return nil, err
	}
	args := map[string]any{
		"sessionId": sid,
		"space":     spaceID,
		// The server names this argument "rights" (not requestedRights).
		"rights": rights,
	}
	if opts != nil {
		if opts.PersistenceMode != "" {
			args["persistenceMode"] = opts.PersistenceMode
		}
		if opts.Reason != "" {
			args["reason"] = opts.Reason
		}
	}
	data, err := c.do("noetic.request_access", args)
	if err != nil {
		return nil, err
	}
	return dataAsMap(data), nil
}

// ListRequests lists pending access requests on spaces you own (owner side).
func (c *Client) ListRequests() ([]map[string]any, error) {
	sid, err := c.requireSession()
	if err != nil {
		return nil, err
	}
	data, err := c.do("noetic.list_requests", map[string]any{"sessionId": sid})
	if err != nil {
		return nil, err
	}
	var wrap struct {
		Requests []map[string]any `json:"requests"`
	}
	_ = json.Unmarshal(data, &wrap)
	return wrap.Requests, nil
}

// ApproveRequest approves a pending access request, minting the grant (owner
// side). Pass nil opts to keep the request's own rights.
func (c *Client) ApproveRequest(requestID string, opts *ApproveRequestOptions) (*GrantResult, error) {
	sid, err := c.requireSession()
	if err != nil {
		return nil, err
	}
	args := map[string]any{"sessionId": sid, "requestId": requestID}
	if opts != nil {
		if len(opts.Rights) > 0 {
			args["rights"] = opts.Rights
		}
		if opts.WorldMutation != "" {
			args["worldMutation"] = opts.WorldMutation
		}
		if opts.PersistenceMode != "" {
			args["persistenceMode"] = opts.PersistenceMode
		}
	}
	data, err := c.do("noetic.approve_request", args)
	if err != nil {
		return nil, err
	}
	return grantResult(data, "noetic.approve_request")
}

// DenyRequest denies a pending access request (owner side).
func (c *Client) DenyRequest(requestID string) (map[string]any, error) {
	sid, err := c.requireSession()
	if err != nil {
		return nil, err
	}
	data, err := c.do("noetic.deny_request", map[string]any{"sessionId": sid, "requestId": requestID})
	if err != nil {
		return nil, err
	}
	return dataAsMap(data), nil
}

func grantResult(data json.RawMessage, method string) (*GrantResult, error) {
	var r GrantResult
	raw, err := decodeInto(data, method, &r)
	if err != nil {
		return nil, err
	}
	r.Raw = raw
	return &r, nil
}

// --------------------------------------------------------------------------- //
// Discovery + introspection
// --------------------------------------------------------------------------- //

// Discover lists publicly discoverable spaces. No session is required. Pass ""
// query and 0 limit for the server defaults.
func (c *Client) Discover(query string, limit int) ([]map[string]any, error) {
	args := map[string]any{}
	if query != "" {
		args["query"] = query
	}
	if limit > 0 {
		args["limit"] = limit
	}
	data, err := c.do("noetic.discover", args)
	if err != nil {
		return nil, err
	}
	var wrap struct {
		Spaces []map[string]any `json:"spaces"`
	}
	_ = json.Unmarshal(data, &wrap)
	return wrap.Spaces, nil
}

// Publish sets a space's discovery visibility. An empty visibility defaults to
// "public".
func (c *Client) Publish(spaceID, visibility string) (map[string]any, error) {
	sid, err := c.requireSession()
	if err != nil {
		return nil, err
	}
	if visibility == "" {
		visibility = "public"
	}
	data, err := c.do("noetic.publish", map[string]any{"sessionId": sid, "space": spaceID, "visibility": visibility})
	if err != nil {
		return nil, err
	}
	return dataAsMap(data), nil
}

// Metrics returns scope/account/space usage metrics for the session.
func (c *Client) Metrics() (map[string]any, error) {
	sid, err := c.requireSession()
	if err != nil {
		return nil, err
	}
	data, err := c.do("noetic.metrics", map[string]any{"sessionId": sid})
	if err != nil {
		return nil, err
	}
	return dataAsMap(data), nil
}
