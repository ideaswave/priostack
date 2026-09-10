// Package priostack is the official Go client for the Priostack Agent Context
// Network (ACN).
//
// The ACN is a Model Context Protocol (MCP) server reached over JSON-RPC 2.0.
// An agent self-registers, opens a session with the returned bearer token,
// creates isolated context spaces, stores typed facts, reads them back, and
// shares them with other agents through scoped capability grants.
//
// This client speaks the exact wire contract of the live server: every call is
// a JSON-RPC tools/call whose result carries the tool envelope as a JSON string
// in result.content[0].text. The client unwraps that envelope, returns a typed
// [ToolError] when the envelope reports ok=false, and returns a [TransportError]
// for network, HTTP, decoding, or JSON-RPC protocol faults. One *http.Client is
// reused across calls and the JSON-RPC id is incremented per request.
//
// # Quickstart
//
//	client := priostack.New()
//	defer client.Close()
//
//	if _, err := client.Register("my-agent"); err != nil { // token captured internally
//		log.Fatal(err)
//	}
//	if _, err := client.Connect("", 0); err != nil { // session id captured internally
//		log.Fatal(err)
//	}
//	space, err := client.CreateSpace("prod-memory", nil)
//	if err != nil {
//		log.Fatal(err)
//	}
//	if _, err := client.Store(space.SpaceID, []priostack.StoreObject{
//		{Content: "Refunds over $500 need manager approval.", Type: "declaration"},
//	}); err != nil {
//		log.Fatal(err)
//	}
//	hits, err := client.Fetch(space.SpaceID, "refund", 0)
//	if err != nil {
//		log.Fatal(err)
//	}
//	for _, obj := range hits.Objects {
//		fmt.Println(obj.Content)
//	}
//
// # Errors
//
// Tool-level denials carry a server outcome. Test for a specific one with
// errors.Is against the exported sentinels, and reach the detail/data with
// errors.As:
//
//	_, err := client.Store(space.SpaceID, objects)
//	if errors.Is(err, priostack.ErrCapabilityDenied) {
//		// the session lacks the write right / mutate capability
//	}
package priostack
