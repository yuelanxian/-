package auth

import (
	"context"
	"errors"
	"sync"
	"time"

	"homevault/panel/internal/nextcloud"
)

// FlowState is the state of a pending Login Flow v2.
type FlowState string

const (
	FlowPending FlowState = "pending"
	FlowDone    FlowState = "done"
	FlowFailed  FlowState = "failed"
)

// ErrTooManyFlows is returned when too many flows are pending at once.
var ErrTooManyFlows = errors.New("too many pending login flows")

// Poller is the subset of the Nextcloud client used by flows.
type Poller interface {
	StartFlow(ctx context.Context, clientIP string) (*nextcloud.Flow, error)
	PollFlow(ctx context.Context, f *nextcloud.Flow) (*nextcloud.Credentials, error)
}

// AuthorizeFunc checks fresh credentials (admin membership). The returned error's
// message is shown to the user.
type AuthorizeFunc func(ctx context.Context, cr *nextcloud.Credentials, clientIP string) (*nextcloud.User, error)

// PendingFlow is a login flow the panel polls in the background.
type PendingFlow struct {
	ID       string
	LoginURL string
	ClientIP string
	Created  time.Time

	mu      sync.Mutex
	state   FlowState
	message string
	creds   *nextcloud.Credentials
	user    *nextcloud.User
	cancel  context.CancelFunc
}

// State returns the current state and a user-facing message.
func (p *PendingFlow) State() (FlowState, string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.state, p.message
}

// Flows manages pending login flows. The panel polls Nextcloud server-side, so the
// browser/WebView may navigate away to the Nextcloud login page and come back later.
type Flows struct {
	NC        Poller
	Authorize AuthorizeFunc
	Revoke    func(cr *nextcloud.Credentials)
	Interval  time.Duration
	Lifetime  time.Duration
	Max       int

	mu    sync.Mutex
	flows map[string]*PendingFlow
	wg    sync.WaitGroup
	base  context.Context
	stop  context.CancelFunc
}

// NewFlows creates a flow manager.
func NewFlows(nc Poller, authorize AuthorizeFunc, revoke func(*nextcloud.Credentials), interval, lifetime time.Duration, max int) *Flows {
	ctx, cancel := context.WithCancel(context.Background())
	return &Flows{NC: nc, Authorize: authorize, Revoke: revoke, Interval: interval, Lifetime: lifetime,
		Max: max, flows: map[string]*PendingFlow{}, base: ctx, stop: cancel}
}

// Start initiates a new flow and begins polling it in the background.
func (fm *Flows) Start(ctx context.Context, clientIP string) (*PendingFlow, error) {
	fm.mu.Lock()
	if fm.Max > 0 && len(fm.flows) >= fm.Max {
		fm.mu.Unlock()
		return nil, ErrTooManyFlows
	}
	fm.mu.Unlock()

	f, err := fm.NC.StartFlow(ctx, clientIP)
	if err != nil {
		return nil, err
	}
	pctx, cancel := context.WithTimeout(fm.base, fm.Lifetime)
	p := &PendingFlow{ID: RandomToken(32), LoginURL: f.LoginURL, ClientIP: clientIP,
		Created: time.Now(), state: FlowPending, cancel: cancel}
	fm.mu.Lock()
	fm.flows[key(p.ID)] = p
	fm.mu.Unlock()
	fm.wg.Add(1)
	go fm.poll(pctx, p, f)
	return p, nil
}

func (fm *Flows) poll(ctx context.Context, p *PendingFlow, f *nextcloud.Flow) {
	defer fm.wg.Done()
	defer p.cancel()
	t := time.NewTicker(fm.Interval)
	defer t.Stop()
	failures := 0
	for {
		select {
		case <-ctx.Done():
			fm.expire(p)
			return
		case <-t.C:
		}
		rctx, cancel := context.WithTimeout(ctx, 15*time.Second)
		cr, err := fm.NC.PollFlow(rctx, f)
		cancel()
		if errors.Is(err, nextcloud.ErrPending) {
			failures = 0
			continue
		}
		if err != nil {
			failures++
			if failures < 10 && ctx.Err() == nil {
				continue // transient (Nextcloud restarting, network hiccup)
			}
			fm.finish(p, FlowFailed, "无法从 Nextcloud 获取登录结果，请重试。", nil, nil)
			fm.linger(ctx, p)
			return
		}
		actx, acancel := context.WithTimeout(fm.base, 20*time.Second)
		u, aerr := fm.Authorize(actx, cr, p.ClientIP)
		acancel()
		if aerr != nil {
			if fm.Revoke != nil {
				fm.Revoke(cr)
			}
			fm.finish(p, FlowFailed, aerr.Error(), nil, nil)
			fm.linger(ctx, p)
			return
		}
		fm.finish(p, FlowDone, "", cr, u)
		// Keep the result until it is taken or the flow lifetime ends.
		<-ctx.Done()
		fm.expire(p)
		return
	}
}

func (fm *Flows) finish(p *PendingFlow, st FlowState, msg string, cr *nextcloud.Credentials, u *nextcloud.User) {
	p.mu.Lock()
	p.state, p.message, p.creds, p.user = st, msg, cr, u
	p.mu.Unlock()
}

// linger keeps a failed flow visible for a short while so the UI can show why, then drops it.
func (fm *Flows) linger(ctx context.Context, p *PendingFlow) {
	t := time.NewTimer(2 * time.Minute)
	defer t.Stop()
	select {
	case <-ctx.Done():
	case <-t.C:
	}
	fm.expire(p)
}

// expire drops a flow whose lifetime ended; unclaimed credentials are revoked.
func (fm *Flows) expire(p *PendingFlow) {
	fm.mu.Lock()
	_, present := fm.flows[key(p.ID)]
	delete(fm.flows, key(p.ID))
	fm.mu.Unlock()
	p.mu.Lock()
	cr := p.creds
	p.creds = nil
	if p.state == FlowPending {
		p.state, p.message = FlowFailed, "登录已超时，请重新登录。"
	}
	p.mu.Unlock()
	if present && cr != nil && fm.Revoke != nil {
		fm.Revoke(cr)
	}
}

// Get returns the flow for a cookie value (or nil).
func (fm *Flows) Get(id string) *PendingFlow {
	if id == "" {
		return nil
	}
	fm.mu.Lock()
	defer fm.mu.Unlock()
	return fm.flows[key(id)]
}

// Take consumes a completed flow and returns its credentials and user.
func (fm *Flows) Take(id string) (*nextcloud.Credentials, *nextcloud.User, bool) {
	fm.mu.Lock()
	p, ok := fm.flows[key(id)]
	if ok {
		p.mu.Lock()
		if p.state != FlowDone || p.creds == nil {
			p.mu.Unlock()
			fm.mu.Unlock()
			return nil, nil, false
		}
		cr, u := p.creds, p.user
		p.creds = nil
		p.mu.Unlock()
		delete(fm.flows, key(id))
		fm.mu.Unlock()
		p.cancel()
		return cr, u, true
	}
	fm.mu.Unlock()
	return nil, nil, false
}

// Cancel aborts a flow (credentials obtained but not taken are revoked).
func (fm *Flows) Cancel(id string) {
	if p := fm.Get(id); p != nil {
		p.cancel()
	}
}

// Pending returns the number of flows being tracked.
func (fm *Flows) Pending() int {
	fm.mu.Lock()
	defer fm.mu.Unlock()
	return len(fm.flows)
}

// Shutdown stops all pollers and revokes unclaimed credentials.
func (fm *Flows) Shutdown() {
	fm.stop()
	fm.wg.Wait()
}
