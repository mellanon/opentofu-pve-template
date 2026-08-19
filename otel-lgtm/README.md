
# Testing observability options for Claude Code

WARNING: For internal-network/homelab use ONLY. Not a secure configuration!

[docker-otel-lgtm](https://github.com/grafana/docker-otel-lgtm/)

## Graphana

- Connect to http://YOURVMIPADDRESS:3000
- Login as admin with the password set in .env
- Dashboards > claude
- More apps > Claude Code stats

## Claude settings.json additions

IMPORTANT: Update host.name for each setup — it is what separates machines in the
dashboards. Note that `user.id` set here does **not** reach Prometheus: Claude Code
emits its own `user.id` as a metric datapoint attribute (an opaque per-install hash),
and a datapoint attribute always wins over a promoted resource attribute of the same
name. Use the `user_email` label for readable per-person identity in Prometheus
queries. Keep `user.id` set anyway — it survives intact as a resource attribute on
Tempo traces (verified), where there is no such collision.

```json
{
  "env": {
    "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
    "CLAUDE_CODE_ENHANCED_TELEMETRY_BETA": "1",
    "OTEL_METRICS_EXPORTER": "otlp",
    "OTEL_LOGS_EXPORTER": "otlp",
    "OTEL_TRACES_EXPORTER": "otlp",
    "OTEL_EXPORTER_OTLP_PROTOCOL": "http/protobuf",
    "OTEL_EXPORTER_OTLP_ENDPOINT": "http://YOURVMIPADDRESS:4318",
    "OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE": "cumulative",
    "OTEL_METRIC_EXPORT_INTERVAL": "10000",
    "OTEL_LOGS_EXPORT_INTERVAL": "5000",
    "OTEL_LOG_USER_PROMPTS": "1",
    "OTEL_LOG_TOOL_DETAILS": "1",
    "OTEL_LOG_TOOL_CONTENT": "1",
    "OTEL_METRICS_INCLUDE_ACCOUNT_UUID": "true",
    "OTEL_METRICS_INCLUDE_SESSION_ID": "true",
    "OTEL_RESOURCE_ATTRIBUTES": "user.id=CHANGEME,host.name=CHANGEME"
  }
}
```

## Ports

- 3000: Grafana UI — where you’ll view your traces
- 4318: OTLP HTTP/protobuf — what Claude Code uses
- 3200: Tempo API — used later for querying traces programmatically

For reference, the other ports in the container: 
- 3000 (Grafana)
- 3100 (Loki)
- 3200 (Tempo)
- 4040 (Pyroscope)
- 4317 (OTLP/gRPC)
- 4318 (OTLP/HTTP)
- 9090 (Prometheus)
- 9411 (Zipkin)

# References

https://github.com/anthropics/claude-code-monitoring-guide/

