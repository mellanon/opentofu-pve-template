sudo docker run --rm --entrypoint cat grafana/otel-lgtm:0.29.2 /otel-lgtm/tempo-config.yaml > tempo-config.yaml.orig
sudo docker run --rm --entrypoint cat grafana/otel-lgtm:0.29.2 /otel-lgtm/prometheus.yaml > prometheus.yaml.orig
sudo docker run --rm --entrypoint cat grafana/otel-lgtm:0.29.2 /otel-lgtm/obi-config.yaml > obi-config.yaml.orig
sudo docker run --rm --entrypoint cat grafana/otel-lgtm:0.29.2 /otel-lgtm/pyroscope-config.yaml > pyroscope-config.yaml.orig
sudo docker run --rm --entrypoint cat grafana/otel-lgtm:0.29.2 /otel-lgtm/loki-config.yaml > loki-config.yaml.orig
sudo docker run --rm --entrypoint cat grafana/otel-lgtm:0.29.2 /otel-lgtm/otelcol-config.yaml > otelcol-config.yaml.orig
sudo docker run --rm --entrypoint cat grafana/otel-lgtm:0.29.2 /otel-lgtm/grafana/conf/provisioning/datasources/grafana-datasources.yaml > grafana-datasources.yaml.orig
