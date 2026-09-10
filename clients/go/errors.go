package priostack

import (
	"encoding/json"
	"errors"
	"fmt"
)

// Error is implemented by every error this package returns — both
// [TransportError] and [ToolError]. It is the Go analogue of the Python
// client's ACNError base: a single type to match when any ACN failure should be
// handled the same way.
//
//	var e priostack.Error
//	if errors.As(err, &e) {
//		// err originated in the ACN client
//	}
type Error interface {
	error
	isACNError()
}

// TransportError is a network, HTTP, decoding, or JSON-RPC protocol failure —
// raised before a valid tool envelope could be obtained: connection errors,
// timeouts, non-2xx HTTP responses, non-JSON bodies, envelopes missing the
// content[0].text payload, or a JSON-RPC error object.
type TransportError struct {
	// Message is the human-readable description (already carries the tool
	// name where one is known).
	Message string
	// Method is the tool name (noetic.*) the failing call targeted, if known.
	Method string
	// Code is the JSON-RPC error code when the failure was a JSON-RPC error
	// object; 0 otherwise.
	Code int
	// HTTPStatus is the HTTP status when the failure was an HTTP error; 0
	// otherwise.
	HTTPStatus int
}

func (e *TransportError) Error() string { return e.Message }
func (e *TransportError) isACNError()   {}

// Outcome is a server outcome string reported on a failed envelope.
type Outcome string

// The outcomes the ACN reports on a failed envelope (ok=false).
const (
	OutcomeNotFound           Outcome = "not-found"
	OutcomeInvalidQuery       Outcome = "invalid-query"
	OutcomeCapabilityDenied   Outcome = "capability-denied"
	OutcomePolicyDenied       Outcome = "policy-denied"
	OutcomeRequiresGovernance Outcome = "requires-governance"
	OutcomeStaleBase          Outcome = "stale-base"
	OutcomeIntegrityFault     Outcome = "integrity-fault"
	OutcomeConflict           Outcome = "conflict"
	OutcomeCapacityExhausted  Outcome = "capacity-exhausted"
	OutcomeNotSupported       Outcome = "not-implemented"
)

// Sentinel errors, one per known outcome. A [ToolError] unwraps to the sentinel
// for its outcome, so callers can match a specific denial with errors.Is:
//
//	if errors.Is(err, priostack.ErrNotFound) { ... }
//
// An unknown/new server outcome degrades gracefully: the [ToolError] still
// carries the raw Outcome string, it just does not match any sentinel.
var (
	ErrNotFound           = errors.New("not-found")
	ErrInvalidQuery       = errors.New("invalid-query")
	ErrCapabilityDenied   = errors.New("capability-denied")
	ErrPolicyDenied       = errors.New("policy-denied")
	ErrRequiresGovernance = errors.New("requires-governance")
	ErrStaleBase          = errors.New("stale-base")
	ErrIntegrityFault     = errors.New("integrity-fault")
	ErrConflict           = errors.New("conflict")
	ErrCapacityExhausted  = errors.New("capacity-exhausted")
	ErrNotSupported       = errors.New("not-implemented")
)

var outcomeSentinels = map[Outcome]error{
	OutcomeNotFound:           ErrNotFound,
	OutcomeInvalidQuery:       ErrInvalidQuery,
	OutcomeCapabilityDenied:   ErrCapabilityDenied,
	OutcomePolicyDenied:       ErrPolicyDenied,
	OutcomeRequiresGovernance: ErrRequiresGovernance,
	OutcomeStaleBase:          ErrStaleBase,
	OutcomeIntegrityFault:     ErrIntegrityFault,
	OutcomeConflict:           ErrConflict,
	OutcomeCapacityExhausted:  ErrCapacityExhausted,
	OutcomeNotSupported:       ErrNotSupported,
}

// ToolError is returned when a tool reached the server but declined the call
// (envelope ok=false). It carries the server Outcome and human-readable Detail,
// and unwraps to the matching sentinel so errors.Is works.
type ToolError struct {
	// Outcome is the server outcome string (e.g. "capability-denied").
	Outcome Outcome
	// Detail is the server's human-readable message, if any.
	Detail string
	// Method is the tool name (noetic.*) that declined the call.
	Method string
	// Data is any partial payload the server attached to the failure (for
	// example the objects stored before a capacity fault), as raw JSON.
	// nil when the server attached none.
	Data json.RawMessage
}

func (e *ToolError) Error() string {
	msg := e.Detail
	if msg == "" {
		msg = "ACN tool error"
	}
	if e.Outcome != "" {
		msg = fmt.Sprintf("%s [%s]", msg, e.Outcome)
	}
	if e.Method != "" {
		return e.Method + ": " + msg
	}
	return msg
}

func (e *ToolError) isACNError() {}

// Unwrap returns the sentinel error for this tool error's outcome, enabling
// errors.Is(err, ErrNotFound) and friends. It returns nil for an unrecognized
// outcome.
func (e *ToolError) Unwrap() error { return outcomeSentinels[e.Outcome] }

// AsToolError extracts a *ToolError from err (via errors.As), reporting whether
// one was found. A convenience over errors.As for the common case.
func AsToolError(err error) (*ToolError, bool) {
	var te *ToolError
	if errors.As(err, &te) {
		return te, true
	}
	return te, false
}

func toolErrorFor(outcome, detail, method string, data json.RawMessage) *ToolError {
	return &ToolError{Outcome: Outcome(outcome), Detail: detail, Method: method, Data: data}
}
