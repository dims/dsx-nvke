# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Settings of block C (fixed addresses on a node network). Source this file after bin/env.sh.
export NODENET=kata-bb-node            # second Docker network of the lab: the node network
export NODEBR_HOST=br-katanode         # its bridge on the machine
export NODESUBNET=172.28.0.0/16 NODERANGE=172.28.0.0/24 NODEGW=172.28.0.1
export NODEIF=nodenet0                 # the interface of a kind node on the node network
export NODEBR=br-node                  # the bridge in each kind node: nodenet0 and the pod interfaces are its ports
export NAD=nodenet                     # the NetworkAttachmentDefinition
