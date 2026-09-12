// Command share runs the sharing half of the ACN flow: two agents, one space, an explicit grant.
//
// The quickstart command shows one agent keeping its own memory. This is the reason the network
// exists: an owner agent stores knowledge, a second agent registers separately, and the owner
// grants it scoped read + quote on that one space. Nothing is shared until the grant exists, the
// grant names the grantee's agent id, and it can be revoked in one call.
//
//	go run ./example/share
//
// Against a self-hosted or local node:
//
//	PRIOSTACK_ENDPOINT=http://127.0.0.1:8091/rpc go run ./example/share
package main

import (
	"errors"
	"fmt"
	"log"
	"os"

	priostack "github.com/ideaswave/priostack/clients/go"
)

func main() {
	var opts []priostack.Option
	if endpoint := os.Getenv("PRIOSTACK_ENDPOINT"); endpoint != "" {
		opts = append(opts, priostack.WithEndpoint(endpoint))
	}

	fmt.Println("1. onboarding two agents")
	owner, _ := onboard("go-owner", opts)
	defer owner.Close()
	worker, workerID := onboard("go-worker", opts)
	defer worker.Close()

	// DefaultRights is the ceiling of what this space may ever offer. It grants nothing by itself:
	// until there is a grant, only the owner can read it.
	space, err := owner.CreateSpace("shift-handover", &priostack.CreateSpaceOptions{
		DefaultRights: []string{"read", "quote"},
	})
	if err != nil {
		log.Fatalf("create space: %v", err)
	}
	fmt.Printf("2. owner created space %s\n", space.SpaceID)

	stored, err := owner.Store(space.SpaceID, []priostack.StoreObject{
		{Content: "Night shift found a stuck consumer on queue orders-v2.", Type: "observation"},
		{Content: "Restarting the consumer requires a change ticket after 22:00.", Type: "declaration"},
	})
	if err != nil {
		log.Fatalf("store: %v", err)
	}
	fmt.Printf("3. owner stored %d object(s)\n", stored.Count())

	// Before the grant the space is not merely empty to the worker — it is not there at all.
	if canRead(worker, space.SpaceID) {
		fmt.Println("4. worker could read the space BEFORE a grant — that would be a bug")
	} else {
		fmt.Println("4. worker cannot see the space yet (as expected)")
	}

	// The subject of a grant is the grantee's AGENT ID, not its display name or its account.
	grant, err := owner.GrantAccess(space.SpaceID, workerID, &priostack.GrantOptions{
		Rights: []string{"read", "quote"},
	})
	if err != nil {
		log.Fatalf("grant: %v", err)
	}
	fmt.Printf("5. granted %v (%s)\n", grant.EffectiveRights, grant.CapabilityRef)

	// The grantee reconnects so its session picks up the widened scope.
	if _, err := worker.Connect("", 0); err != nil {
		log.Fatalf("reconnect: %v", err)
	}
	hits, err := worker.Fetch(space.SpaceID, "consumer", 0)
	if err != nil {
		log.Fatalf("fetch: %v", err)
	}
	fmt.Printf("6. worker reads %d of %d object(s):\n", hits.Matched, hits.Total)
	for _, obj := range hits.Objects {
		fmt.Printf("     - %s\n", obj.Content)
	}

	// Revoking is immediate and forward-only: the worker keeps nothing it has already read, and
	// loses the space on its next session.
	if _, err := owner.RevokeAccess(grant.CapabilityRef); err != nil {
		log.Fatalf("revoke: %v", err)
	}
	if _, err := worker.Connect("", 0); err != nil {
		log.Fatalf("reconnect: %v", err)
	}
	if canRead(worker, space.SpaceID) {
		fmt.Println("7. worker still reads the space after revoke — that would be a bug")
	} else {
		fmt.Println("7. grant revoked — the worker cannot read the space any more")
	}
}

// onboard registers one agent and opens its session.
func onboard(displayName string, opts []priostack.Option) (*priostack.Client, string) {
	c := priostack.New(opts...)
	reg, err := c.Register(displayName)
	if err != nil {
		log.Fatalf("register %s: %v", displayName, err)
	}
	if _, err := c.Connect("", 0); err != nil {
		log.Fatalf("connect %s: %v", displayName, err)
	}
	fmt.Printf("  %s: agent %s\n", displayName, reg.AgentID)
	return c, reg.AgentID
}

// canRead reports whether this client can reach the space at all. A space it holds no capability
// on answers not-found, which is the same answer a space that does not exist gives: the network
// does not confirm the existence of context you were never granted.
func canRead(c *priostack.Client, spaceID string) bool {
	if _, err := c.Fetch(spaceID, "", 0); err != nil {
		if errors.Is(err, priostack.ErrNotFound) {
			return false
		}
		log.Fatalf("fetch: %v", err)
	}
	return true
}
