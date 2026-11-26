package main

import (
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func setupTestServer() http.Handler {
	cfg := Config{
		Port:       "8080",
		LogLevel:   slog.LevelError,
		Env:        "test",
		AppVersion: "1.2.3",
	}
	logger := slog.New(slog.NewJSONHandler(io.Discard, nil))
	return instrumentHandler(logger, newRouter(cfg))
}

func TestRootEndpoint(t *testing.T) {
	handler := setupTestServer()
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	rec := httptest.NewRecorder()

	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d", rec.Code)
	}

	var body map[string]string
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("failed to parse JSON response: %v", err)
	}

	if body["message"] != "Hello from DevOps Task!" {
		t.Errorf("unexpected message: %q", body["message"])
	}
	if body["status"] != "running" {
		t.Errorf("unexpected status: %q", body["status"])
	}
	if body["version"] != "1.2.3" {
		t.Errorf("unexpected version: %q", body["version"])
	}
}

func TestHealthEndpoint(t *testing.T) {
	handler := setupTestServer()
	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	rec := httptest.NewRecorder()

	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d", rec.Code)
	}

	var body map[string]string
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("failed to parse JSON response: %v", err)
	}

	if body["status"] != "healthy" {
		t.Errorf("expected status healthy, got %q", body["status"])
	}
}

func TestMetricsEndpoint(t *testing.T) {
	handler := setupTestServer()

	handler.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/", nil))
	handler.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/does-not-exist", nil))

	req := httptest.NewRequest(http.MethodGet, "/metrics", nil)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d", rec.Code)
	}

	metricsOutput := rec.Body.String()
	expectedMetrics := []string{
		"http_requests_total",
		"http_request_errors_total",
		"http_request_duration_seconds_bucket",
	}

	for _, metric := range expectedMetrics {
		if !strings.Contains(metricsOutput, metric) {
			t.Errorf("expected metric %q in /metrics output", metric)
		}
	}
}