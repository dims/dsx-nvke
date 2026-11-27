# The node image for pods, form p4: the form p3 with ONE change, the NVKE agent binary with the
# fix of the upload-certs step (branch fix/agent-upload-certs-config, commit f240606c).
ARG P3=nvke-node-podvm:bcc4376f-p3
FROM ${P3}
ARG AGENT_SHA256
COPY nvke-agent /usr/local/bin/nvke-agent
RUN set -eu; \
    chmod 0755 /usr/local/bin/nvke-agent; \
    echo "${AGENT_SHA256}  /usr/local/bin/nvke-agent" | sha256sum -c -; \
    ls -l /usr/local/bin/nvke-agent
LABEL podvm.image-form="p4: p3 with the agent of commit f240606c" podvm.agent-sha256="${AGENT_SHA256}"
