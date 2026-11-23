FROM ghcr.io/gleam-lang/gleam:v1.18.1-erlang
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends python3-venv && rm -rf /var/lib/apt/lists/*
COPY gleam.toml manifest.toml ./
RUN gleam deps download
COPY src/ src/
COPY dev/ dev/
RUN gleam build --warnings-as-errors
# The driver is the uv project under antithesis/; pip installs it and its
# pinned SDK dependency into an isolated venv.
COPY antithesis/pyproject.toml antithesis/README.md /opt/antithesis/catalog/
COPY antithesis/src/ /opt/antithesis/catalog/src/
RUN python3 -m venv /opt/sdk && /opt/sdk/bin/pip install --no-cache-dir /opt/antithesis/catalog
COPY --chmod=755 antithesis/templates/v3/ /opt/antithesis/test/v1/v3/
ENTRYPOINT []
CMD ["sh", "-ec", "/opt/sdk/bin/python -c 'from antithesis.lifecycle import setup_complete; setup_complete({\"template\": \"v3\"})'; exec sleep infinity"]
