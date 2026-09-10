// Command quickstart runs the canonical ACN flow against the live endpoint:
// register -> connect -> create space -> store -> fetch, printing each result.
//
// All network calls live inside main, so importing the priostack library never
// fires a request. Usage:
//
//	go run ./example/quickstart [displayName]
//
// The endpoint defaults to https://priostack.com/mcp and can be overridden with
// the PRIOSTACK_ENDPOINT environment variable.
package main

import (
	"fmt"
	"log"
	"os"

	priostack "github.com/ideaswave/priostack/clients/go"
)

func main() {
	displayName := "go-sdk-smoke"
	if len(os.Args) > 1 && os.Args[1] != "" {
		displayName = os.Args[1]
	}

	var opts []priostack.Option
	if endpoint := os.Getenv("PRIOSTACK_ENDPOINT"); endpoint != "" {
		opts = append(opts, priostack.WithEndpoint(endpoint))
	}

	client := priostack.New(opts...)
	defer client.Close()

	reg, err := client.Register(displayName)
	if err != nil {
		log.Fatalf("register: %v", err)
	}
	fmt.Printf("registered agent %s (account %s, tier %s)\n", reg.AgentID, reg.AccountID, reg.Tier)

	conn, err := client.Connect("", 0)
	if err != nil {
		log.Fatalf("connect: %v", err)
	}
	fmt.Printf("session %s (account %q, max tokens %d)\n", conn.SessionID, conn.ResolvedAccount, conn.ResolvedMaxTokens)

	space, err := client.CreateSpace("go-sdk-quickstart", nil)
	if err != nil {
		log.Fatalf("create space: %v", err)
	}
	fmt.Printf("created space %s\n", space.SpaceID)

	stored, err := client.Store(space.SpaceID, []priostack.StoreObject{
		{Content: "Refunds over $500 need manager approval.", Type: "declaration"},
		{Content: "Customer #402 started the export pipeline.", Type: "observation"},
	})
	if err != nil {
		log.Fatalf("store: %v", err)
	}
	fmt.Printf("stored %d objects\n", stored.Count())

	hits, err := client.Fetch(space.SpaceID, "refund", 0)
	if err != nil {
		log.Fatalf("fetch: %v", err)
	}
	fmt.Printf("fetched %d of %d objects (%d tokens):\n", hits.Matched, hits.Total, hits.ReturnedTokens)
	for _, obj := range hits.Objects {
		fmt.Printf("  - [%s] %s\n", obj.Kind, obj.Content)
	}
}
