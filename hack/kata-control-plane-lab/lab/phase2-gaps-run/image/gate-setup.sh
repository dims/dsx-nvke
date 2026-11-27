#!/bin/sh
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Image build step of the form p6: make the probe program and the drop-in of the agent unit from
# the one settings file endpoint-gate.env. The Dockerfile runs it with no argument. A test can
# give another root folder as the first argument.
set -eu
ROOT=${1:-}
LIB=$ROOT/usr/local/lib/podvm
UNIT=$ROOT/etc/systemd/system/nvke-agent.service
AGENT=$ROOT/usr/local/bin/nvke-agent
PROBE=$ROOT/usr/local/bin/podvm-endpoint-ready
DROPIN=$UNIT.d/zz-podvm-endpoint-gate.conf
. "$LIB/endpoint-gate.env"

# The drop-in replaces the ExecStart line of the unit. Stop if the unit of the base image is not
# the unit that this step knows.
grep -q -x 'ExecStart=/usr/local/bin/nvke-agent \$AGENT_ARGS' "$UNIT" || { echo "ERROR: $UNIT has another ExecStart line than this build expects"; exit 1; }

# Each flag must be a flag of the agent binary of this image. An agent stops at a flag that it
# does not know, and then the node never answers.
if [ -z "${SKIP_FLAG_CHECK:-}" ]; then
  "$AGENT" --help >/tmp/podvm-agent-help.txt 2>&1 || true
  for f in $AGENT_GATE_FLAGS; do
    n=${f%%=*}
    grep -q -E "^[[:space:]]+-${n#--}([[:space:]]|\$)" /tmp/podvm-agent-help.txt || { echo "ERROR: the agent binary has no flag $n"; exit 1; }
  done
  rm -f /tmp/podvm-agent-help.txt
fi

# The probe program.
sed "s|@GATE_FILE@|$GATE_FILE|" "$LIB/podvm-endpoint-ready.in" >"$PROBE"
chmod 0755 "$PROBE"
rm "$LIB/podvm-endpoint-ready.in"
grep -q -F "[ -e \"$GATE_FILE\" ] && exit 1" "$PROBE" || { echo "ERROR: the probe program does not read $GATE_FILE"; exit 1; }

# The folder of the gate file. It is in /var of the image, so the entry point copies it to the
# /var volume at the first use. ExecStartPre makes it on a volume that an older image filled.
GATE_DIR=$(dirname "$GATE_FILE")
mkdir -p "$ROOT$GATE_DIR"
mkdir -p "$UNIT.d"
cat >"$DROPIN" <<UNITEOF
# Made at image build time from /usr/local/lib/podvm/endpoint-gate.env. Do not change it here.
# The NVKE agent gets the health gate of the shared address: the gate file that the readiness
# probe of the pod reads (/usr/local/bin/podvm-endpoint-ready), the interface on which the
# connections of the Service arrive, and the settle time.
[Service]
Environment="PODVM_AGENT_GATE_FLAGS=$AGENT_GATE_FLAGS"
ExecStartPre=/usr/bin/mkdir -p $GATE_DIR
ExecStart=
ExecStart=/usr/local/bin/nvke-agent \$AGENT_ARGS \$PODVM_AGENT_GATE_FLAGS
UNITEOF
chmod 0644 "$DROPIN"
echo "== $PROBE"; cat "$PROBE"
echo "== $DROPIN"; cat "$DROPIN"
