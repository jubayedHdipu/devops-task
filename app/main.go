package main

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

type Config struct {
	Port       string
	LogLevel   slog.Level
	Env        string
	AppVersion string
}

func loadConfig() Config {
	port := getEnv("PORT", "8080")
	env := getEnv("APP_ENV", "production")
	version := getEnv("APP_VERSION", "1.0.0")
	levelStr := strings.ToLower(getEnv("LOG_LEVEL", "info"))

	var level slog.Level
	switch levelStr {
	case "debug":
		level = slog.LevelDebug
	case "warn", "warning":
		level = slog.LevelWarn
	case "error":
		level = slog.LevelError
	default:
		level = slog.LevelInfo
	}

	return Config{
		Port:       port,
		LogLevel:   level,
		Env:        env,
		AppVersion: version,
	}
}

func getEnv(key, fallback string) string {
	if val, ok := os.LookupEnv(key); ok && strings.TrimSpace(val) != "" {
		return val
	}
	return fallback
}

var (
	httpRequestsTotal = promauto.NewCounterVec(
		prometheus.CounterOpts{
			Name: "http_requests_total",
			Help: "Total number of HTTP requests processed",
		},
		[]string{"method", "path", "status"},
	)

	httpErrorsTotal = promauto.NewCounterVec(
		prometheus.CounterOpts{
			Name: "http_request_errors_total",
			Help: "Total number of HTTP requests resulting in 4xx or 5xx errors",
		},
		[]string{"method", "path", "status"},
	)

	httpRequestDuration = promauto.NewHistogramVec(
		prometheus.HistogramOpts{
			Name:    "http_request_duration_seconds",
			Help:    "HTTP request latency distribution in seconds",
			Buckets: prometheus.DefBuckets,
		},
		[]string{"method", "path"},
	)
)

type statusRecorder struct {
	http.ResponseWriter
	statusCode int
}

func (r *statusRecorder) WriteHeader(code int) {
	r.statusCode = code
	r.ResponseWriter.WriteHeader(code)
}

func instrumentHandler(logger *slog.Logger, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, statusCode: http.StatusOK}

		next.ServeHTTP(rec, r)

		duration := time.Since(start).Seconds()
		statusStr := strconv.Itoa(rec.statusCode)
		path := normalizePath(r.URL.Path)

		httpRequestsTotal.WithLabelValues(r.Method, path, statusStr).Inc()
		httpRequestDuration.WithLabelValues(r.Method, path).Observe(duration)

		if rec.statusCode >= 400 {
			httpErrorsTotal.WithLabelValues(r.Method, path, statusStr).Inc()
		}

		if path == "/health" || path == "/metrics" {
			logger.Debug("request completed",
				"method", r.Method,
				"path", path,
				"status", rec.statusCode,
				"duration_ms", duration*1000,
			)
			return
		}

		logFn := logger.Info
		if rec.statusCode >= 500 {
			logFn = logger.Error
		} else if rec.statusCode >= 400 {
			logFn = logger.Warn
		}

		logFn("request completed",
			"method", r.Method,
			"path", path,
			"status", rec.statusCode,
			"duration_ms", duration*1000,
			"remote_addr", r.RemoteAddr,
		)
	})
}

func normalizePath(p string) string {
	switch p {
	case "/", "/health", "/metrics":
		return p
	default:
		return "/other"
	}
}

func newRouter(cfg Config) *http.ServeMux {
	mux := http.NewServeMux()

	mux.HandleFunc("GET /", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "not found"})
			return
		}
		writeJSON(w, http.StatusOK, map[string]string{
			"message": "Hello from DevOps Task!",
			"status":  "running",
			"version": cfg.AppVersion,
		})
	})

	mux.HandleFunc("GET /health", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]string{
			"status":      "healthy",
			"environment": cfg.Env,
			"version":     cfg.AppVersion,
		})
	})

	mux.Handle("GET /metrics", promhttp.Handler())

	return mux
}

func writeJSON(w http.ResponseWriter, status int, payload any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(payload)
}

func main() {
	cfg := loadConfig()

	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: cfg.LogLevel,
	})).With(
		"service", "devops-task-app",
		"env", cfg.Env,
		"version", cfg.AppVersion,
	)

	srv := &http.Server{
		Addr:              ":" + cfg.Port,
		Handler:           instrumentHandler(logger, newRouter(cfg)),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      10 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	serverErrors := make(chan error, 1)
	go func() {
		logger.Info("starting HTTP server", "port", cfg.Port)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			serverErrors <- err
		}
	}()

	shutdown := make(chan os.Signal, 1)
	signal.Notify(shutdown, syscall.SIGINT, syscall.SIGTERM)

	select {
	case err := <-serverErrors:
		logger.Error("server failed to start", "error", err)
		os.Exit(1)
	case sig := <-shutdown:
		logger.Info("shutdown signal received, draining connections", "signal", sig.String())
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()

		if err := srv.Shutdown(ctx); err != nil {
			logger.Error("graceful shutdown failed, forcing close", "error", err)
			_ = srv.Close()
			os.Exit(1)
		}
		logger.Info("server stopped cleanly")
	}
}