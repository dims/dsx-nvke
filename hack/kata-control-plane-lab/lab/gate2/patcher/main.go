// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

// patcher sends a steady rate of merge patches to ConfigMaps of one cluster.
// It uses the Go standard library only, so the build needs no module download.
//
// The program makes the namespace and the ConfigMaps, then sends one patch at each tick.
// Each patch changes two small fields. The API server then writes the full object to etcd.
// It prints one line of counts and latency each report interval.
package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"flag"
	"fmt"
	"io"
	"math/rand"
	"net/http"
	"os"
	"os/signal"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

type target struct {
	base   string
	client *http.Client
}

type stats struct {
	mu        sync.Mutex
	latencies []time.Duration
	ok        int64
	failed    int64
	dropped   int64
	lastError string
}

func (s *stats) add(d time.Duration, err error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err != nil {
		s.failed++
		s.lastError = err.Error()
		return
	}
	s.ok++
	s.latencies = append(s.latencies, d)
}

// take returns the counts and the latency percentiles since the last call.
func (s *stats) take() (ok, failed, dropped int64, p50, p99, max time.Duration, lastError string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	lat := s.latencies
	sort.Slice(lat, func(i, j int) bool { return lat[i] < lat[j] })
	if n := len(lat); n > 0 {
		p50, p99, max = lat[n/2], lat[n*99/100], lat[n-1]
	}
	ok, failed, dropped, lastError = s.ok, s.failed, s.dropped, s.lastError
	s.latencies, s.ok, s.failed, s.dropped, s.lastError = nil, 0, 0, 0, ""
	return
}

func newClient(caFile, certFile, keyFile string) (*http.Client, error) {
	ca, err := os.ReadFile(caFile)
	if err != nil {
		return nil, fmt.Errorf("reading the CA file: %w", err)
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(ca) {
		return nil, fmt.Errorf("no certificate in %s", caFile)
	}
	cert, err := tls.LoadX509KeyPair(certFile, keyFile)
	if err != nil {
		return nil, fmt.Errorf("loading the client certificate: %w", err)
	}
	transport := &http.Transport{
		TLSClientConfig:     &tls.Config{RootCAs: pool, Certificates: []tls.Certificate{cert}, MinVersion: tls.VersionTLS12},
		ForceAttemptHTTP2:   true,
		MaxIdleConnsPerHost: 8,
		IdleConnTimeout:     5 * time.Minute,
	}
	return &http.Client{Transport: transport, Timeout: 30 * time.Second}, nil
}

// send makes one request and returns an error for a status that is not in the accepted list.
func send(ctx context.Context, t target, method, path, contentType, body string, accept ...int) error {
	req, err := http.NewRequestWithContext(ctx, method, t.base+path, bytes.NewBufferString(body))
	if err != nil {
		return fmt.Errorf("making the request: %w", err)
	}
	req.Header.Set("Content-Type", contentType)
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", "gate2-patcher")
	resp, err := t.client.Do(req)
	if err != nil {
		return fmt.Errorf("%s %s: %w", method, path, err)
	}
	defer resp.Body.Close()
	// Read the body to its end, so that the connection is free for the next request.
	_, _ = io.Copy(io.Discard, resp.Body)
	for _, code := range accept {
		if resp.StatusCode == code {
			return nil
		}
	}
	return fmt.Errorf("%s %s: status %d", method, path, resp.StatusCode)
}

func payload(size int) string {
	const letters = "abcdefghijklmnopqrstuvwxyz0123456789"
	b := make([]byte, size)
	for i := range b {
		b[i] = letters[rand.Intn(len(letters))]
	}
	return string(b)
}

func main() {
	servers := flag.String("servers", "", "API server URLs, separated by commas. The patches go to them in turn")
	caFile := flag.String("ca", "/creds/ca.crt", "CA certificate of the API server")
	certFile := flag.String("cert", "/creds/tls.crt", "client certificate")
	keyFile := flag.String("key", "/creds/tls.key", "client key")
	namespace := flag.String("namespace", "gate2-load", "namespace of the ConfigMaps")
	objects := flag.Int("objects", 200, "number of ConfigMaps")
	rate := flag.Float64("rate", 23, "patches each second")
	size := flag.Int("payload", 2048, "bytes of data in each ConfigMap")
	report := flag.Duration("report", 30*time.Second, "interval of the report lines")
	inFlight := flag.Int("in-flight", 64, "maximum number of open requests")
	flag.Parse()
	if *servers == "" || *rate <= 0 || *objects <= 0 {
		fmt.Fprintln(os.Stderr, "set -servers, -rate and -objects")
		os.Exit(2)
	}

	var targets []target
	for _, s := range strings.Split(*servers, ",") {
		client, err := newClient(*caFile, *certFile, *keyFile)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		targets = append(targets, target{base: strings.TrimRight(s, "/"), client: client})
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()

	// Setup: the namespace and the ConfigMaps. A 409 means that the object exists.
	nsBody := fmt.Sprintf(`{"apiVersion":"v1","kind":"Namespace","metadata":{"name":%q}}`, *namespace)
	for try := 1; ; try++ {
		err := send(ctx, targets[0], http.MethodPost, "/api/v1/namespaces", "application/json", nsBody, 201, 409)
		if err == nil {
			break
		}
		fmt.Printf("%s setup: %v (try %d)\n", time.Now().UTC().Format(time.RFC3339), err, try)
		if try == 30 {
			os.Exit(1)
		}
		time.Sleep(2 * time.Second)
	}
	for i := 0; i < *objects; i++ {
		body := fmt.Sprintf(`{"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"obj-%04d"},"data":{"seq":"0","stamp":"","payload":%q}}`, i, payload(*size))
		path := fmt.Sprintf("/api/v1/namespaces/%s/configmaps", *namespace)
		if err := send(ctx, targets[i%len(targets)], http.MethodPost, path, "application/json", body, 201, 409); err != nil {
			fmt.Printf("%s setup: %v\n", time.Now().UTC().Format(time.RFC3339), err)
			os.Exit(1)
		}
	}
	fmt.Printf("%s setup done: %d ConfigMaps of %d bytes in %s. Rate %.1f patches each second to %d server(s).\n",
		time.Now().UTC().Format(time.RFC3339), *objects, *size, *namespace, *rate, len(targets))

	var st stats
	var sent int64
	slots := make(chan struct{}, *inFlight)
	interval := time.Duration(float64(time.Second) / *rate)
	start := time.Now()

	go func() {
		ticker := time.NewTicker(*report)
		defer ticker.Stop()
		last := time.Now()
		for range ticker.C {
			ok, failed, dropped, p50, p99, max, lastError := st.take()
			now := time.Now()
			fmt.Printf("%s unix=%d sent_total=%d ok=%d failed=%d dropped=%d rate=%.2f p50_ms=%.1f p99_ms=%.1f max_ms=%.1f %s\n",
				now.UTC().Format(time.RFC3339), now.Unix(), atomic.LoadInt64(&sent), ok, failed, dropped,
				float64(ok)/now.Sub(last).Seconds(), float64(p50)/1e6, float64(p99)/1e6, float64(max)/1e6, lastError)
			last = now
		}
	}()

	// One patch at each tick. The schedule is from the start time, so a slow tick does not move the rate.
	for i := int64(0); ; i++ {
		next := start.Add(time.Duration(i) * interval)
		select {
		case <-ctx.Done():
			fmt.Printf("%s stop after %d patches\n", time.Now().UTC().Format(time.RFC3339), atomic.LoadInt64(&sent))
			return
		case <-time.After(time.Until(next)):
		}
		select {
		case slots <- struct{}{}:
		default:
			st.mu.Lock()
			st.dropped++
			st.mu.Unlock()
			continue
		}
		atomic.AddInt64(&sent, 1)
		go func(i int64) {
			defer func() { <-slots }()
			name := fmt.Sprintf("obj-%04d", i%int64(*objects))
			path := fmt.Sprintf("/api/v1/namespaces/%s/configmaps/%s", *namespace, name)
			body := fmt.Sprintf(`{"data":{"seq":"%d","stamp":%q}}`, i, time.Now().UTC().Format(time.RFC3339Nano))
			begin := time.Now()
			err := send(ctx, targets[int(i)%len(targets)], http.MethodPatch, path, "application/merge-patch+json", body, 200)
			st.add(time.Since(begin), err)
		}(i)
	}
}
