package auth

import (
	"sync"
	"time"
)

// Limiter is a sliding-window rate limiter keyed by an arbitrary string (client IP).
type Limiter struct {
	Limit  int
	Window time.Duration

	mu   sync.Mutex
	hits map[string][]time.Time
	now  func() time.Time
}

// NewLimiter allows at most limit events per window per key.
func NewLimiter(limit int, window time.Duration) *Limiter {
	return &Limiter{Limit: limit, Window: window, hits: map[string][]time.Time{}, now: time.Now}
}

// Allow records an event for key and reports whether it is within the limit.
func (l *Limiter) Allow(key string) bool {
	now := l.now()
	l.mu.Lock()
	defer l.mu.Unlock()
	h := prune(l.hits[key], now.Add(-l.Window))
	if len(h) >= l.Limit {
		l.hits[key] = h
		return false
	}
	l.hits[key] = append(h, now)
	return true
}

// RetryAfter returns how long until key may try again (0 if allowed now).
func (l *Limiter) RetryAfter(key string) time.Duration {
	now := l.now()
	l.mu.Lock()
	defer l.mu.Unlock()
	h := prune(l.hits[key], now.Add(-l.Window))
	if len(h) < l.Limit || len(h) == 0 {
		return 0
	}
	return h[0].Add(l.Window).Sub(now)
}

// Reset forgets key (e.g. after a successful login).
func (l *Limiter) Reset(key string) {
	l.mu.Lock()
	delete(l.hits, key)
	l.mu.Unlock()
}

// Sweep removes stale keys.
func (l *Limiter) Sweep() {
	cutoff := l.now().Add(-l.Window)
	l.mu.Lock()
	for k, h := range l.hits {
		if h = prune(h, cutoff); len(h) == 0 {
			delete(l.hits, k)
		} else {
			l.hits[k] = h
		}
	}
	l.mu.Unlock()
}

func prune(h []time.Time, cutoff time.Time) []time.Time {
	i := 0
	for i < len(h) && !h[i].After(cutoff) {
		i++
	}
	if i == 0 {
		return h
	}
	return append(h[:0:0], h[i:]...)
}
