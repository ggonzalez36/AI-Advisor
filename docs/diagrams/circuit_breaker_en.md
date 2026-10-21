# Circuit Breaker Diagram (English)

```mermaid
graph TD
    Request([Risk Evaluation Request]) --> CB{Circuit Breaker\nMiddleware}

    subgraph ClosedState ["State: CLOSED (Normal Operation)"]
        CB -- Allowed Request --> OAI[LangChain OpenAI Strategy]
        OAI -- 200 OK --> Response([Successful Response])
        OAI -- 500 / Timeout --> ErrorCounter[Increment Failure Counter]
    end

    ErrorCounter -. Failures > Threshold .-> OpenState((Switch to OPEN state))

    subgraph OpenState ["State: OPEN (Fast Failure)"]
        OpenState -. Activates .-> CB
        CB -- Intercepts Request --> Fallback[Fallback Rule-Based Strategy]
        Fallback --> FallbackResponse([Degraded but Fast Response])
    end
    
    OpenState -. After 30s .-> HalfOpen((State: HALF-OPEN\nTraffic Test))
    HalfOpen -. Successful test request .-> Close((Return to CLOSED))
    HalfOpen -. Test request fails .-> KeepOpen((Stay OPEN))

    classDef closed fill:#d4edda,stroke:#28a745,color:#155724;
    classDef open fill:#f8d7da,stroke:#dc3545,color:#721c24;
    classDef warning fill:#fff3cd,stroke:#ffc107,color:#856404;
    
    class ClosedState,OAI,Response closed;
    class OpenState,Fallback,FallbackResponse open;
    class HalfOpen warning;
```

![Circuit Breaker Diagram (English)](circuit_breaker_en.jpg)
