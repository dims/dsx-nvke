      runtimeClassName: ${RUNTIME_CLASS} #@runtimeclass
      # The node needs no token of the host cluster.
      automountServiceAccountToken: false
      enableServiceLinks: false
      restartPolicy: Always
      terminationGracePeriodSeconds: ${GRACE}
      containers:
        - name: node
          image: ${IMAGE}
          imagePullPolicy: Never
          # The wrapper prepares the volumes, the node state, the node address and the Open vSwitch
          # changes, then starts the kind entrypoint.
          command: ["/g1/wrapper.sh"]
          tty: true
          securityContext:
            privileged: true
          env:
            - {name: KIND_EXPERIMENTAL_CONTAINERD_SNAPSHOTTER, value: "${SNAPSHOTTER}"}
            # nico-sim sets this variable for the node container.
            - {name: KUBECONFIG, value: /etc/kubernetes/admin.conf}
            - {name: G1_GUEST, value: "1"} #@runtimeclass
            # Wrapper steps to leave out. "init-cgroup" for a Kata class with the exec fix.
            - {name: G1_SKIP, value: "${G1_SKIP}"}
            - {name: G1_STOP_TIMEOUT, value: "${STOP_TIMEOUT}"}
            # The node address: the LoadBalancer IP of the Service of this node (gate 4).
            - {name: G4_NODE_IP, value: "${NODE_IP}"}
            - {name: G4_ADDR_FORM, value: "${ADDR_FORM}"}
            - {name: G4_REPAIR, value: "${REPAIR}"}
            # The etcd settings of gate 4 as a kubeadm patch file.
            - {name: P1_ETCD_PATCH, value: "${ETCD_PATCH}"}
            # nvke-agent with --disable-mtls. Identity is not under test here.
            - {name: G1N_AGENT_PLAINTEXT, value: "1"}
            - {name: G1N_SKIP_UNITS, value: ""}
            # Phase 1 step 1: the userspace datapath and the two image changes.
            - {name: P1_OVS_DATAPATH, value: "${P1_OVS_DATAPATH}"}
            - {name: P1_OVS_NO_MODPROBE, value: "${P1_OVS_NO_MODPROBE}"}
            - {name: P1_TUN, value: "${P1_TUN}"}
            - {name: P1_KMOD_NOOP, value: "0"}
          # Requests are equal to limits. The Kata Rust runtime sizes the VM from the limits.
          resources:
            limits: {cpu: "${CPU}", memory: ${MEMORY}}
          # The pod is ready when its API server is ready.
          readinessProbe:
            httpGet: {path: /readyz, port: 6443, scheme: HTTPS}
            periodSeconds: 2
            failureThreshold: 1
          volumeDevices:
            - {name: var, devicePath: /dev/g1-var}
            - {name: etcd, devicePath: /dev/g1-etcd}
          volumeMounts:
            - {name: run, mountPath: /run}
            - {name: tmp, mountPath: /tmp}
            - {name: wrapper, mountPath: /g1, readOnly: true}
            - {name: kernel-config, mountPath: /g1-kernel, readOnly: true} #@kernelconfig
      volumes:
        - name: run
          emptyDir: {medium: Memory}
        - name: tmp
          emptyDir: {medium: Memory}
        - name: wrapper
          configMap: {name: p1-wrapper, defaultMode: 0755}
        - name: kernel-config #@kernelconfig
          configMap: {name: p1-kernel-config} #@kernelconfig
