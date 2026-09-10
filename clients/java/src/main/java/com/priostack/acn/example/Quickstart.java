package com.priostack.acn.example;

import com.priostack.acn.ACNClient;
import com.priostack.acn.FetchResult;
import com.priostack.acn.RegisterResult;
import com.priostack.acn.SpaceResult;
import com.priostack.acn.StoreObject;
import com.priostack.acn.StoreResult;
import java.util.List;

/**
 * End-to-end smoke test of the Priostack ACN Java client:
 * register &rarr; connect &rarr; createSpace &rarr; store &rarr; fetch.
 *
 * <p>All live calls happen inside {@link #main}, so loading this class fires no
 * network traffic. Run it with:
 *
 * <pre>{@code
 *   mvn -q compile
 *   mvn -q exec:java -Dexec.args="java-sdk-smoke"
 * }</pre>
 *
 * <p>The first argument (optional) is the display name to register under; the
 * second (optional) overrides the endpoint.
 */
public final class Quickstart {

    private Quickstart() {}

    public static void main(String[] args) {
        String displayName = args.length > 0 ? args[0] : "java-sdk-smoke";
        String endpoint = args.length > 1 ? args[1] : ACNClient.DEFAULT_ENDPOINT;

        try (ACNClient acn = new ACNClient(endpoint)) {
            RegisterResult reg = acn.register(displayName);
            System.out.println("registered  agentId=" + reg.agentId() + " tier=" + reg.tier());

            acn.connect(); // session id captured internally from PascalCase SessionID
            System.out.println("connected   sessionId=" + acn.sessionId());

            SpaceResult space = acn.createSpace(displayName + "-memory");
            System.out.println("created     spaceId=" + space.spaceId());

            StoreResult stored =
                    acn.store(
                            space.spaceId(),
                            List.of(
                                    StoreObject.declaration(
                                            "Refunds over $500 need manager approval."),
                                    StoreObject.observation(
                                            "Customer #4417 asked about a refund on order 9921."),
                                    StoreObject.measurement("p95 refund latency: 2300 ms")));
            System.out.println("stored      count=" + stored.count());

            FetchResult hits = acn.fetch(space.spaceId(), "refund");
            System.out.println(
                    "fetched     matched=" + hits.matched() + " of total=" + hits.total());
            for (String content : hits.contents()) {
                System.out.println("  - " + content);
            }
        }
    }
}
