package auth

import (
	"context"
	"errors"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"homevault/panel/internal/nextcloud"
)

func TestSessionStore(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	st := NewStore(time.Hour, 2)
	st.now = func() time.Time { return now }
	var ended sync.WaitGroup
	var endedCount atomic.Int32
	st.OnEnd = func(*Session) { endedCount.Add(1); ended.Done() }

	a := st.Create("alice", "Alice", nextcloud.Credentials{LoginName: "alice", AppPassword: "p1"}, true, "flow", "1.2.3.4")
	if st.Get(a.ID) != a || st.Get("nope") != nil || st.Get("") != nil {
		t.Fatal("lookup failed")
	}
	if !a.CheckCSRF(a.CSRF) || a.CheckCSRF("") || a.CheckCSRF(a.CSRF+"x") {
		t.Fatal("csrf check broken")
	}
	if a.ID == a.CSRF || len(a.ID) < 40 {
		t.Fatal("weak tokens")
	}
	now = now.Add(10 * time.Minute)
	b := st.Create("bob", "", nextcloud.Credentials{}, false, "app-password", "")
	// third session evicts the oldest (alice)
	ended.Add(1)
	c := st.Create("carol", "", nextcloud.Credentials{}, false, "app-password", "")
	ended.Wait()
	if st.Get(a.ID) != nil || st.Get(b.ID) == nil || st.Get(c.ID) == nil || st.Count() != 2 {
		t.Fatal("eviction wrong")
	}
	// expiry
	ended.Add(2)
	now = now.Add(2 * time.Hour)
	if st.Get(b.ID) != nil {
		t.Fatal("expired session returned")
	}
	st.Sweep()
	ended.Wait()
	if st.Count() != 0 || endedCount.Load() != 3 {
		t.Fatalf("count=%d ended=%d", st.Count(), endedCount.Load())
	}
}

func TestNeedsRecheck(t *testing.T) {
	s := &Session{lastCheck: time.Unix(1000, 0)}
	if s.NeedsRecheck(time.Unix(1100, 0), 5*time.Minute) {
		t.Fatal("too early")
	}
	if !s.NeedsRecheck(time.Unix(1400, 0), 5*time.Minute) || s.NeedsRecheck(time.Unix(1401, 0), 5*time.Minute) {
		t.Fatal("recheck should be claimed once")
	}
}

func TestLimiter(t *testing.T) {
	now := time.Unix(0, 0)
	l := NewLimiter(3, time.Minute)
	l.now = func() time.Time { return now }
	for i := 0; i < 3; i++ {
		if !l.Allow("ip") {
			t.Fatal("should allow")
		}
	}
	if l.Allow("ip") || l.RetryAfter("ip") <= 0 {
		t.Fatal("should block")
	}
	if !l.Allow("other") {
		t.Fatal("keys must be independent")
	}
	now = now.Add(61 * time.Second)
	if !l.Allow("ip") {
		t.Fatal("window should slide")
	}
	l.Reset("ip")
	l.Sweep()
}

type fakePoller struct {
	mu        sync.Mutex
	pollsLeft int
	err       error
}

func (f *fakePoller) StartFlow(ctx context.Context, ip string) (*nextcloud.Flow, error) {
	return &nextcloud.Flow{LoginURL: "https://nc/login/v2/flow/x", PollToken: "t", PollPath: "/login/v2/poll"}, nil
}

func (f *fakePoller) PollFlow(ctx context.Context, fl *nextcloud.Flow) (*nextcloud.Credentials, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.err != nil {
		return nil, f.err
	}
	if f.pollsLeft > 0 {
		f.pollsLeft--
		return nil, nextcloud.ErrPending
	}
	return &nextcloud.Credentials{LoginName: "admin", AppPassword: "secret"}, nil
}

func waitState(t *testing.T, p *PendingFlow, want FlowState) string {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if st, msg := p.State(); st == want {
			return msg
		}
		time.Sleep(5 * time.Millisecond)
	}
	st, msg := p.State()
	t.Fatalf("state = %s (%s), want %s", st, msg, want)
	return ""
}

func TestFlowSuccessAndTake(t *testing.T) {
	var revoked atomic.Int32
	fm := NewFlows(&fakePoller{pollsLeft: 2},
		func(ctx context.Context, cr *nextcloud.Credentials, ip string) (*nextcloud.User, error) {
			return &nextcloud.User{ID: "admin", Groups: []string{"admin"}}, nil
		},
		func(*nextcloud.Credentials) { revoked.Add(1) }, 5*time.Millisecond, time.Minute, 5)
	defer fm.Shutdown()
	p, err := fm.Start(context.Background(), "1.2.3.4")
	if err != nil {
		t.Fatal(err)
	}
	waitState(t, p, FlowDone)
	cr, u, ok := fm.Take(p.ID)
	if !ok || cr.AppPassword != "secret" || u.ID != "admin" {
		t.Fatal("take failed")
	}
	if _, _, ok := fm.Take(p.ID); ok {
		t.Fatal("double take")
	}
	fm.Shutdown()
	if revoked.Load() != 0 {
		t.Fatal("taken credentials must not be revoked")
	}
}

func TestFlowNotAdminRevokes(t *testing.T) {
	var revoked atomic.Int32
	fm := NewFlows(&fakePoller{},
		func(ctx context.Context, cr *nextcloud.Credentials, ip string) (*nextcloud.User, error) {
			return nil, errors.New("只有管理员")
		},
		func(*nextcloud.Credentials) { revoked.Add(1) }, 5*time.Millisecond, time.Minute, 5)
	defer fm.Shutdown()
	p, _ := fm.Start(context.Background(), "")
	if msg := waitState(t, p, FlowFailed); msg != "只有管理员" {
		t.Fatalf("msg %q", msg)
	}
	if revoked.Load() != 1 {
		t.Fatal("credentials of non-admin must be revoked")
	}
	if _, _, ok := fm.Take(p.ID); ok {
		t.Fatal("failed flow must not be taken")
	}
}

func TestFlowUnclaimedRevokedOnExpiry(t *testing.T) {
	var revoked atomic.Int32
	fm := NewFlows(&fakePoller{},
		func(ctx context.Context, cr *nextcloud.Credentials, ip string) (*nextcloud.User, error) {
			return &nextcloud.User{ID: "admin"}, nil
		},
		func(*nextcloud.Credentials) { revoked.Add(1) }, 5*time.Millisecond, 200*time.Millisecond, 5)
	p, _ := fm.Start(context.Background(), "")
	waitState(t, p, FlowDone)
	deadline := time.Now().Add(3 * time.Second)
	for revoked.Load() == 0 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if revoked.Load() != 1 || fm.Get(p.ID) != nil {
		t.Fatalf("revoked=%d", revoked.Load())
	}
	fm.Shutdown()
}

func TestFlowMaxPending(t *testing.T) {
	fm := NewFlows(&fakePoller{pollsLeft: 1 << 30}, nil, nil, time.Hour, time.Minute, 1)
	defer fm.Shutdown()
	if _, err := fm.Start(context.Background(), ""); err != nil {
		t.Fatal(err)
	}
	if _, err := fm.Start(context.Background(), ""); !errors.Is(err, ErrTooManyFlows) {
		t.Fatalf("err = %v", err)
	}
}
