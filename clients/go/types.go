package priostack

// StoreKinds are the object type values the store tool accepts. Anything else
// is rejected server-side with the invalid-query outcome (proposals and
// inferences go through the propose/commit path, not store).
var StoreKinds = []string{"declaration", "observation", "measurement"}

func validStoreKind(kind string) bool {
	for _, k := range StoreKinds {
		if k == kind {
			return true
		}
	}
	return false
}

// StoreObject is one typed fact written into a space by [Client.Store].
//
// Content is required. Type must be one of [StoreKinds]; an empty Type defaults
// to "declaration". Provenance is optional supporting evidence.
type StoreObject struct {
	Content    string   `json:"content"`
	Type       string   `json:"type"`
	Provenance []string `json:"provenance,omitempty"`
}

// RegisterResult is the result of [Client.Register]. Token is shown once by the
// server; the client also stores it internally for later Connect calls.
type RegisterResult struct {
	Token     string `json:"token"`
	AgentID   string `json:"agentId"`
	AccountID string `json:"accountId"`
	Tier      string `json:"tier"`

	// Raw is the full, unwrapped data payload, for fields not surfaced above.
	Raw map[string]any `json:"-"`
}

// ConnectResult is the result of [Client.Connect].
//
// The connect envelope is the one place the server serializes its payload with
// Go (PascalCase) field names, so these JSON tags are PascalCase on purpose.
// SessionID is captured on the client automatically.
type ConnectResult struct {
	SessionID            string   `json:"SessionID"`
	ResolvedAccount      string   `json:"ResolvedAccount"`
	GrantedCapabilities  []string `json:"GrantedCapabilities"`
	GrantedContextRights []string `json:"GrantedContextRights"`
	BoundSpace           string   `json:"BoundSpace"`
	ResolvedMaxTokens    int      `json:"ResolvedMaxTokens"`

	Raw map[string]any `json:"-"`
}

// SpaceResult is the result of [Client.CreateSpace]. Use SpaceID for writes.
type SpaceResult struct {
	SpaceID         string `json:"spaceId"`
	AccountID       string `json:"accountId"`
	PersistenceMode string `json:"persistenceMode"`
	ProtectionLevel string `json:"protectionLevel"`

	Raw map[string]any `json:"-"`
}

// StoreResult is the result of [Client.Store].
type StoreResult struct {
	ObjectRefs []map[string]any `json:"objectRefs"`

	Raw map[string]any `json:"-"`
}

// Count reports how many objects were ingested.
func (r *StoreResult) Count() int { return len(r.ObjectRefs) }

// FetchObject is one stored object returned by [Client.Fetch].
type FetchObject struct {
	ObjectRef string `json:"objectRef"`
	Kind      string `json:"kind"`
	Content   string `json:"content"`
	Tokens    int    `json:"tokens"`
}

// FetchResult is the result of [Client.Fetch], the content reader.
type FetchResult struct {
	Space          string        `json:"space"`
	Objects        []FetchObject `json:"objects"`
	Matched        int           `json:"matched"`
	Total          int           `json:"total"`
	ReturnedTokens int           `json:"returnedTokens"`

	Raw map[string]any `json:"-"`
}

// Contents returns just the content strings of the returned objects.
func (r *FetchResult) Contents() []string {
	out := make([]string, len(r.Objects))
	for i, o := range r.Objects {
		out[i] = o.Content
	}
	return out
}

// GrantResult is the result of [Client.GrantAccess] and
// [Client.ApproveRequest].
type GrantResult struct {
	CapabilityRef   string   `json:"capabilityRef"`
	Subject         string   `json:"subject"`
	Resource        string   `json:"resource"`
	EffectiveRights []string `json:"effectiveRights"`

	Raw map[string]any `json:"-"`
}

// CreateSpaceOptions holds the optional arguments to [Client.CreateSpace]. Pass
// nil for all defaults. DefaultRights is the ceiling of rights the space may
// offer to others; it grants nothing by itself.
type CreateSpaceOptions struct {
	DefaultRights   []string
	Visibility      string
	PersistenceMode string
	ProtectionLevel string
}

// GrantOptions holds the optional arguments to [Client.GrantAccess]. Pass nil
// to grant the default rights (read, quote) and let the server derive the
// world-mutation ladder from them.
type GrantOptions struct {
	// Rights are content rights (read, write, quote, share, export, ...).
	// Empty means the default [read quote].
	Rights []string
	// WorldMutation is the separate mutation ladder (read, propose, mutate).
	// Empty lets the server derive it (granting write confers mutate).
	WorldMutation   string
	PersistenceMode string
}

// RequestAccessOptions holds the optional arguments to [Client.RequestAccess].
type RequestAccessOptions struct {
	PersistenceMode string
	Reason          string
}

// ApproveRequestOptions holds the optional arguments to
// [Client.ApproveRequest]. Empty fields keep the request's own values.
type ApproveRequestOptions struct {
	Rights          []string
	WorldMutation   string
	PersistenceMode string
}
