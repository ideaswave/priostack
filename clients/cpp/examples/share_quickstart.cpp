// Sharing quickstart: two agents, one space, an explicit grant.
//
// quickstart.cpp shows one agent keeping its own memory. This is the other half, and the reason
// the network exists: an owner agent stores knowledge, a second agent registers separately, and
// the owner grants it scoped read + quote on that one space. Nothing is shared until the grant
// exists, the grant names the grantee's agent id, and it can be revoked in one call.
//
//     g++ -std=c++17 -Iinclude examples/share_quickstart.cpp -lcurl -o share_quickstart
//     ./share_quickstart
//
// Against a self-hosted or local node:
//
//     PRIOSTACK_ENDPOINT=http://127.0.0.1:8091/rpc ./share_quickstart

#include <cstdlib>
#include <iostream>
#include <memory>
#include <string>
#include <utility>

#include <priostack/priostack.hpp>

namespace {

std::string endpoint() {
  const char* env = std::getenv("PRIOSTACK_ENDPOINT");
  return (env && *env) ? std::string(env) : std::string(priostack::kDefaultEndpoint);
}

/// Register one agent and open its session.
std::pair<std::unique_ptr<priostack::ACNClient>, std::string> onboard(
    const std::string& display_name) {
  auto acn = std::make_unique<priostack::ACNClient>(endpoint());
  auto reg = acn->register_agent(display_name);
  acn->connect();
  std::cout << "  " << display_name << ": agent " << reg.agent_id << "\n";
  return {std::move(acn), reg.agent_id};
}

/// Whether this client can reach the space at all. A space it holds no capability on answers
/// not-found — the same answer a space that does not exist gives: the network does not confirm
/// the existence of context you were never granted.
bool can_read(priostack::ACNClient& acn, const std::string& space_id) {
  try {
    acn.fetch(space_id);
    return true;
  } catch (const priostack::NotFoundError&) {
    return false;
  }
}

}  // namespace

int main() {
  try {
    std::cout << "1. onboarding two agents\n";
    auto [owner, owner_id] = onboard("cpp-owner");
    auto [worker, worker_id] = onboard("cpp-worker");
    (void)owner_id;

    // default_rights is the ceiling of what this space may ever offer. It grants nothing by
    // itself: until there is a grant, only the owner can read it.
    auto space = owner->create_space("shift-handover",
                                     std::vector<std::string>{"read", "quote"});
    std::cout << "2. owner created space " << space.space_id << "\n";

    auto stored = owner->store(
        space.space_id,
        {{"Night shift found a stuck consumer on queue orders-v2.", "observation"},
         {"Restarting the consumer requires a change ticket after 22:00.", "declaration"}});
    std::cout << "3. owner stored " << stored.count() << " object(s)\n";

    std::cout << (can_read(*worker, space.space_id)
                      ? "4. worker could read the space BEFORE a grant — that would be a bug\n"
                      : "4. worker cannot see the space yet (as expected)\n");

    // The subject of a grant is the grantee's AGENT ID, not its display name or its account.
    auto grant = owner->grant_access(space.space_id, worker_id, {"read", "quote"});
    std::cout << "5. granted ";
    for (size_t i = 0; i < grant.effective_rights.size(); ++i)
      std::cout << (i ? ", " : "") << grant.effective_rights[i];
    std::cout << " (" << grant.capability_ref << ")\n";

    // The grantee reconnects so its session picks up the widened scope.
    worker->connect();
    auto hits = worker->fetch(space.space_id, "consumer");
    std::cout << "6. worker reads " << hits.matched << " of " << hits.total << " object(s):\n";
    for (const auto& content : hits.contents()) std::cout << "     - " << content << "\n";

    // Revoking is immediate and forward-only: the worker keeps nothing it has already read, and
    // loses the space on its next session.
    owner->revoke_access(grant.capability_ref);
    worker->connect();
    std::cout << (can_read(*worker, space.space_id)
                      ? "7. worker still reads the space after revoke — that would be a bug\n"
                      : "7. grant revoked — the worker cannot read the space any more\n");

    return 0;
  } catch (const priostack::ACNError& err) {
    std::cerr << "ACN error: " << err.what() << "\n";
    return 1;
  } catch (const std::exception& err) {
    std::cerr << "error: " << err.what() << "\n";
    return 1;
  }
}
