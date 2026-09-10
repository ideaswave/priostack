// Quickstart: register an agent, store facts, and read them back.
//
// It talks to the live ACN and registers a throwaway agent. Build and run:
//
//     make quickstart        # from clients/cpp/
//     ./quickstart
//
// or manually:
//
//     g++ -std=c++17 -Iinclude examples/quickstart.cpp -lcurl -o quickstart

#include <cstdlib>
#include <iostream>
#include <string>

#include <priostack/priostack.hpp>

int main(int argc, char** argv) {
  // Allow overriding the display name (the smoke test passes its own).
  const std::string display_name = argc > 1 ? argv[1] : "cpp-sdk-quickstart";

  try {
    priostack::ACNClient acn;  // default endpoint, ~30s timeout

    // 1. Self-register (no API key, no dashboard). The token is captured on the
    //    client and returned so you can persist it for next time.
    auto reg = acn.register_agent(display_name);
    std::cout << "1. registered agent " << reg.agent_id << " (tier " << reg.tier
              << ")\n";
    std::cout << "   token (store this, shown once): " << reg.token << "\n";

    // 2. Open a session. The session id is captured internally.
    auto conn = acn.connect();
    std::cout << "2. session " << conn.session_id << " | capabilities [";
    for (size_t i = 0; i < conn.granted_capabilities.size(); ++i)
      std::cout << (i ? ", " : "") << conn.granted_capabilities[i];
    std::cout << "]\n";

    // 3. Create an isolated memory space. Use the RETURNED id for writes.
    auto space = acn.create_space("prod-agent-memory");
    std::cout << "3. created space " << space.space_id << "\n";

    // 4. Persist typed facts. type must be declaration | observation | measurement.
    auto stored = acn.store(
        space.space_id,
        {{"User approved execution workflow #402.", "declaration"},
         {"Export pipeline latency was 1.8s at 14:02 UTC.", "observation"}});
    std::cout << "4. stored " << stored.count() << " objects\n";

    // 5. Read them back. query is a case-insensitive substring filter.
    auto hits = acn.fetch(space.space_id, "workflow");
    std::cout << "5. fetched " << hits.matched << "/" << hits.total
              << " (viewport " << hits.returned_tokens << " tokens):\n";
    for (const auto& content : hits.contents())
      std::cout << "     - " << content << "\n";

    return EXIT_SUCCESS;
  } catch (const priostack::ACNToolError& e) {
    std::cerr << "ACN tool error [" << e.outcome() << "]: " << e.what() << "\n";
  } catch (const priostack::ACNTransportError& e) {
    std::cerr << "ACN transport error: " << e.what() << "\n";
  } catch (const std::exception& e) {
    std::cerr << "error: " << e.what() << "\n";
  }
  return EXIT_FAILURE;
}
