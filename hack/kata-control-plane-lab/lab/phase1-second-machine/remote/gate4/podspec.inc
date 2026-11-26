      runtimeClassName: ${RUNTIME_CLASS} #@runtimeclass
      # The node needs no token of the host cluster.
      automountServiceAccountToken: false
      enableServiceLinks: false
      # Block C with volumes that permit each worker node: prefer the home node of the replica, and #@prefer
      # prefer a node with no other replica. A cordon or a lost node then moves the pod. #@prefer
      affinity: #@prefer
        nodeAffinity: #@prefer
          preferredDuringSchedulingIgnoredDuringExecution: #@prefer
            - {weight: 100, preference: {matchExpressions: [{key: kubernetes.io/hostname, operator: In, values: ["${HOST_NODE}"]}]}} #@prefer
        podAntiAffinity: #@prefer
          preferredDuringSchedulingIgnoredDuringExecution: #@prefer
            - {weight: 50, podAffinityTerm: {topologyKey: kubernetes.io/hostname, labelSelector: {matchLabels: {g4-role: control-plane}}}} #@prefer
      restartPolicy: Always
      # The node stops by itself in 11 to 13 s with the systemd stop timeout of 10 s (gate 1).
      terminationGracePeriodSeconds: ${GRACE}
      containers:
        - name: node
          image: ${IMAGE}
          imagePullPolicy: Never
          # The wrapper prepares the volumes, the node state and the node address, then starts
          # the kind entrypoint.
          command: ["/g1/wrapper.sh"]
          tty: true
          securityContext:
            privileged: true
          env:
            - {name: KIND_EXPERIMENTAL_CONTAINERD_SNAPSHOTTER, value: "${SNAPSHOTTER}"}
            - {name: G1_GUEST, value: "1"} #@runtimeclass
            # Wrapper steps to leave out. "init-cgroup" for a Kata class with the exec fix.
            - {name: G1_SKIP, value: "${G1_SKIP}"}
            - {name: G1_STOP_TIMEOUT, value: "${STOP_TIMEOUT}"}
            # The node address: the LoadBalancer IP of the Service of this replica.
            - {name: G4_NODE_IP, value: "${NODE_IP}"}
            - {name: G4_ADDR_FORM, value: "${ADDR_FORM}"}
            - {name: G4_REPAIR, value: "${REPAIR}"}
          # Requests are equal to limits. The Kata Rust runtime sizes the VM from the limits.
          resources:
            limits: {cpu: "${CPU}", memory: ${MEMORY}}
          # The pod is ready when its API server is ready. The shared Service uses this.
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
          configMap: {name: g4-wrapper, defaultMode: 0755}
        - name: kernel-config #@kernelconfig
          configMap: {name: g4-kernel-config} #@kernelconfig
