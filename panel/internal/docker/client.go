// Package docker is a minimal Docker Engine API client used through the socket proxy.
// Only these calls are made: GET /containers/json, /containers/{id}/json,
// /containers/{id}/logs, /info, /version, /_ping and POST /containers/{id}/restart.
package docker

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	labelProject = "com.docker.compose.project"
	labelService = "com.docker.compose.service"
	labelOneOff  = "com.docker.compose.oneoff"
	maxJSON      = 4 << 20
)

var idRe = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}$`)

// Client talks to the Docker API.
type Client struct {
	base    string
	http    *http.Client
	Project string
}

// New creates a client for DOCKER_HOST (tcp://host:port, http://host:port or unix:///path).
func New(dockerHost, project string) (*Client, error) {
	c := &Client{Project: project}
	tr := &http.Transport{
		MaxIdleConns:        4,
		IdleConnTimeout:     30 * time.Second,
		DisableCompression:  true,
		TLSHandshakeTimeout: 5 * time.Second,
	}
	switch {
	case strings.HasPrefix(dockerHost, "unix://"):
		path := strings.TrimPrefix(dockerHost, "unix://")
		tr.DialContext = func(ctx context.Context, _, _ string) (net.Conn, error) {
			var d net.Dialer
			return d.DialContext(ctx, "unix", path)
		}
		c.base = "http://docker"
	case strings.HasPrefix(dockerHost, "tcp://"):
		c.base = "http://" + strings.TrimPrefix(dockerHost, "tcp://")
	case strings.HasPrefix(dockerHost, "http://"):
		c.base = strings.TrimRight(dockerHost, "/")
	default:
		return nil, fmt.Errorf("docker: unsupported DOCKER_HOST %q", dockerHost)
	}
	c.http = &http.Client{Transport: tr, Timeout: 60 * time.Second}
	return c, nil
}

// APIError is a non-2xx response from the Docker API (or the socket proxy: 403).
type APIError struct {
	Status  int
	Message string
}

func (e *APIError) Error() string {
	return fmt.Sprintf("docker: HTTP %d: %s", e.Status, e.Message)
}

func (c *Client) do(ctx context.Context, method, path string, q url.Values) (*http.Response, error) {
	u := c.base + path
	if len(q) > 0 {
		u += "?" + q.Encode()
	}
	req, err := http.NewRequestWithContext(ctx, method, u, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "homevault-panel")
	resp, err := c.http.Do(req)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode/100 != 2 {
		defer resp.Body.Close()
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 2048))
		var m struct {
			Message string `json:"message"`
		}
		msg := strings.TrimSpace(string(b))
		if json.Unmarshal(b, &m) == nil && m.Message != "" {
			msg = m.Message
		}
		return nil, &APIError{Status: resp.StatusCode, Message: msg}
	}
	return resp, nil
}

func (c *Client) getJSON(ctx context.Context, path string, q url.Values, out any) error {
	resp, err := c.do(ctx, http.MethodGet, path, q)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	return json.NewDecoder(io.LimitReader(resp.Body, maxJSON)).Decode(out)
}

// Ping checks connectivity (GET /_ping).
func (c *Client) Ping(ctx context.Context) error {
	resp, err := c.do(ctx, http.MethodGet, "/_ping", nil)
	if err != nil {
		return err
	}
	resp.Body.Close()
	return nil
}

// Container is a compose service container with state details.
type Container struct {
	ID           string    `json:"id"`
	Service      string    `json:"service"`
	Name         string    `json:"name"`
	Image        string    `json:"image"`
	State        string    `json:"state"`  // running, exited, restarting, ...
	Status       string    `json:"status"` // human readable from Docker
	Health       string    `json:"health"` // healthy, unhealthy, starting, "" (no healthcheck)
	StartedAt    time.Time `json:"started_at"`
	FinishedAt   time.Time `json:"finished_at"`
	RestartCount int       `json:"restart_count"`
	ExitCode     int       `json:"exit_code"`
	Tty          bool      `json:"-"`
}

type summary struct {
	ID     string            `json:"Id"`
	Names  []string          `json:"Names"`
	Image  string            `json:"Image"`
	State  string            `json:"State"`
	Status string            `json:"Status"`
	Labels map[string]string `json:"Labels"`
}

type inspect struct {
	ID    string `json:"Id"`
	Name  string `json:"Name"`
	State struct {
		Status     string `json:"Status"`
		StartedAt  string `json:"StartedAt"`
		FinishedAt string `json:"FinishedAt"`
		ExitCode   int    `json:"ExitCode"`
		Health     *struct {
			Status string `json:"Status"`
		} `json:"Health"`
	} `json:"State"`
	RestartCount int `json:"RestartCount"`
	Config       struct {
		Tty    bool              `json:"Tty"`
		Image  string            `json:"Image"`
		Labels map[string]string `json:"Labels"`
	} `json:"Config"`
}

// Services lists the compose project's service containers (one-off `run` containers excluded),
// inspected for health and start time, sorted by service name.
func (c *Client) Services(ctx context.Context) ([]Container, error) {
	filters, _ := json.Marshal(map[string][]string{"label": {labelProject + "=" + c.Project}})
	var list []summary
	if err := c.getJSON(ctx, "/containers/json", url.Values{"all": {"1"}, "filters": {string(filters)}}, &list); err != nil {
		return nil, err
	}
	byService := map[string]summary{}
	for _, s := range list {
		if s.Labels[labelProject] != c.Project || strings.EqualFold(s.Labels[labelOneOff], "true") {
			continue
		}
		svc := s.Labels[labelService]
		if svc == "" {
			continue
		}
		// Prefer a running container when several exist for one service.
		if prev, ok := byService[svc]; ok && prev.State == "running" {
			continue
		}
		byService[svc] = s
	}
	out := make([]Container, 0, len(byService))
	var mu sync.Mutex
	var wg sync.WaitGroup
	sem := make(chan struct{}, 4)
	for svc, s := range byService {
		ct := Container{ID: s.ID, Service: svc, Image: s.Image, State: s.State, Status: s.Status}
		if len(s.Names) > 0 {
			ct.Name = strings.TrimPrefix(s.Names[0], "/")
		}
		wg.Go(func() {
			sem <- struct{}{}
			defer func() { <-sem }()
			if in, err := c.inspect(ctx, ct.ID); err == nil {
				ct.State = in.State.Status
				ct.StartedAt = parseTime(in.State.StartedAt)
				ct.FinishedAt = parseTime(in.State.FinishedAt)
				ct.ExitCode = in.State.ExitCode
				ct.RestartCount = in.RestartCount
				ct.Tty = in.Config.Tty
				if in.State.Health != nil {
					ct.Health = in.State.Health.Status
				}
			}
			mu.Lock()
			out = append(out, ct)
			mu.Unlock()
		})
	}
	wg.Wait()
	sort.Slice(out, func(i, j int) bool { return out[i].Service < out[j].Service })
	return out, nil
}

func (c *Client) inspect(ctx context.Context, id string) (*inspect, error) {
	if !idRe.MatchString(id) {
		return nil, errors.New("docker: invalid container id")
	}
	var in inspect
	if err := c.getJSON(ctx, "/containers/"+id+"/json", nil, &in); err != nil {
		return nil, err
	}
	return &in, nil
}

// Find returns the container of a compose service.
func (c *Client) Find(ctx context.Context, service string) (*Container, error) {
	list, err := c.Services(ctx)
	if err != nil {
		return nil, err
	}
	for i := range list {
		if list[i].Service == service {
			return &list[i], nil
		}
	}
	return nil, ErrNotFound
}

// ErrNotFound means no container exists for the requested service.
var ErrNotFound = errors.New("docker: service container not found")

// Logs returns the last `tail` lines of a container's stdout+stderr (demultiplexed),
// limited to maxBytes of output.
func (c *Client) Logs(ctx context.Context, ct *Container, tail int, timestamps bool, maxBytes int64) ([]byte, bool, error) {
	if !idRe.MatchString(ct.ID) {
		return nil, false, errors.New("docker: invalid container id")
	}
	q := url.Values{"stdout": {"1"}, "stderr": {"1"}, "tail": {strconv.Itoa(tail)}}
	if timestamps {
		q.Set("timestamps", "1")
	}
	resp, err := c.do(ctx, http.MethodGet, "/containers/"+ct.ID+"/logs", q)
	if err != nil {
		return nil, false, err
	}
	defer resp.Body.Close()
	var buf bytes.Buffer
	lw := &limitWriter{w: &buf, n: maxBytes}
	br := bufio.NewReaderSize(resp.Body, 64<<10)
	ctype := resp.Header.Get("Content-Type")
	multiplexed := !ct.Tty
	if strings.Contains(ctype, "application/vnd.docker.raw-stream") {
		multiplexed = false
	} else if strings.Contains(ctype, "application/vnd.docker.multiplexed-stream") {
		multiplexed = true
	}
	if multiplexed && !LooksMultiplexed(br) {
		multiplexed = false
	}
	if multiplexed {
		err = Demux(lw, br)
	} else {
		_, err = io.Copy(lw, br)
	}
	truncated := false
	if errors.Is(err, errLimit) {
		truncated, err = true, nil
	}
	return buf.Bytes(), truncated, err
}

// Restart restarts a container (POST /containers/{id}/restart?t=timeout).
func (c *Client) Restart(ctx context.Context, ct *Container, timeout int) error {
	if !idRe.MatchString(ct.ID) {
		return errors.New("docker: invalid container id")
	}
	resp, err := c.do(ctx, http.MethodPost, "/containers/"+ct.ID+"/restart", url.Values{"t": {strconv.Itoa(timeout)}})
	if err != nil {
		return err
	}
	resp.Body.Close()
	return nil
}

// Info is a subset of GET /info.
type Info struct {
	ServerVersion   string `json:"server_version"`
	OperatingSystem string `json:"operating_system"`
	OSType          string `json:"os_type"`
	KernelVersion   string `json:"kernel_version"`
	Architecture    string `json:"architecture"`
	NCPU            int    `json:"ncpu"`
	MemTotal        int64  `json:"mem_total"`
	Containers      int    `json:"containers"`
	Running         int    `json:"running"`
	Name            string `json:"name"`
}

// Info returns host/engine information.
func (c *Client) Info(ctx context.Context) (*Info, error) {
	var r struct {
		ServerVersion     string `json:"ServerVersion"`
		OperatingSystem   string `json:"OperatingSystem"`
		OSType            string `json:"OSType"`
		KernelVersion     string `json:"KernelVersion"`
		Architecture      string `json:"Architecture"`
		NCPU              int    `json:"NCPU"`
		MemTotal          int64  `json:"MemTotal"`
		Containers        int    `json:"Containers"`
		ContainersRunning int    `json:"ContainersRunning"`
		Name              string `json:"Name"`
	}
	if err := c.getJSON(ctx, "/info", nil, &r); err != nil {
		return nil, err
	}
	return &Info{ServerVersion: r.ServerVersion, OperatingSystem: r.OperatingSystem, OSType: r.OSType,
		KernelVersion: r.KernelVersion, Architecture: r.Architecture, NCPU: r.NCPU, MemTotal: r.MemTotal,
		Containers: r.Containers, Running: r.ContainersRunning, Name: r.Name}, nil
}

// Version returns the engine version and API version (GET /version).
func (c *Client) Version(ctx context.Context) (string, string, error) {
	var r struct {
		Version    string `json:"Version"`
		APIVersion string `json:"ApiVersion"`
	}
	if err := c.getJSON(ctx, "/version", nil, &r); err != nil {
		return "", "", err
	}
	return r.Version, r.APIVersion, nil
}

func parseTime(s string) time.Time {
	t, err := time.Parse(time.RFC3339Nano, s)
	if err != nil || t.Year() < 2000 {
		return time.Time{}
	}
	return t
}
