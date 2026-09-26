// Command panel is the HomeVault management panel (server side of the Android app).
//
//	panel serve        run the HTTP server (default)
//	panel healthcheck  exit 0 if the local server answers /healthz (Docker HEALTHCHECK)
//	panel version      print the version
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
	_ "time/tzdata" // scratch image has no zoneinfo; TZ=Asia/Shanghai must still work

	"homevault/panel/internal/config"
	"homevault/panel/internal/server"
)

// version is set at build time: -ldflags "-X main.version=..."
var version = "dev"

func main() {
	cmd := "serve"
	if len(os.Args) > 1 {
		cmd = os.Args[1]
	}
	switch cmd {
	case "serve":
		os.Exit(serve())
	case "healthcheck":
		os.Exit(healthcheck())
	case "version", "--version", "-v":
		fmt.Println(version)
	default:
		fmt.Fprintf(os.Stderr, "用法: panel [serve|healthcheck|version]\n")
		os.Exit(2)
	}
}

func serve() int {
	logger := slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	slog.SetDefault(logger)

	cfg, err := config.Load()
	if err != nil {
		slog.Error("configuration error", "err", err)
		return 1
	}
	srv, err := server.New(cfg, version)
	if err != nil {
		slog.Error("startup failed", "err", err)
		return 1
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	hs := &http.Server{
		Addr:              cfg.ListenAddr(),
		Handler:           srv.Handler(),
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      10 * time.Minute, // log / APK downloads
		IdleTimeout:       2 * time.Minute,
		MaxHeaderBytes:    32 << 10,
		ErrorLog:          slog.NewLogLogger(logger.Handler(), slog.LevelWarn),
	}
	go srv.Run(ctx)

	errc := make(chan error, 1)
	go func() {
		slog.Info("HomeVault panel listening", "addr", hs.Addr, "version", version,
			"nextcloud", cfg.NCInternalURL.String(), "public", cfg.PublicURL.String(), "docker", cfg.DockerHost)
		errc <- hs.ListenAndServe()
	}()

	select {
	case err := <-errc:
		if !errors.Is(err, http.ErrServerClosed) {
			slog.Error("server failed", "err", err)
			return 1
		}
	case <-ctx.Done():
	}
	slog.Info("shutting down")
	sctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	_ = hs.Shutdown(sctx)
	srv.Shutdown(sctx)
	slog.Info("stopped")
	return 0
}

func healthcheck() int {
	port := "8080"
	if cfg, err := config.Load(); err == nil {
		port = cfg.ListenPort()
	}
	c := &http.Client{Timeout: 4 * time.Second}
	resp, err := c.Get("http://127.0.0.1:" + port + "/healthz")
	if err != nil {
		fmt.Fprintln(os.Stderr, "unhealthy:", err)
		return 1
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		fmt.Fprintln(os.Stderr, "unhealthy: HTTP", resp.StatusCode)
		return 1
	}
	return 0
}
