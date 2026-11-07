FROM ghcr.io/gleam-lang/gleam:v1.18.1-erlang
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends python3-venv && rm -rf /var/lib/apt/lists/*
RUN python3 -m venv /opt/sdk && /opt/sdk/bin/pip install --no-cache-dir antithesis==0.4.1
COPY gleam.toml manifest.toml ./
RUN gleam deps download
COPY src/ src/
RUN gleam build
COPY antithesis/probe.erl ./
RUN erlc -Werror probe.erl
COPY antithesis/driver.py /opt/antithesis/catalog/driver.py
COPY --chmod=755 antithesis/templates/v3/ /opt/antithesis/test/v1/v3/
ENTRYPOINT []
CMD ["sh", "-ec", "/opt/sdk/bin/python -c 'from antithesis.lifecycle import setup_complete; setup_complete({\"template\": \"v3\"})'; exec sleep infinity"]
