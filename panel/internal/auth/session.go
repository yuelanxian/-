// Package auth implements in-memory sessions, pending Nextcloud login flows and rate limiting.
package auth

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"sync"
	"time"

	"homevault/panel/internal/nextcloud"
)

// Session is an authenticated panel session. The app password lives only here (in memory).
type Session struct {
	ID          string
	CSRF        string
	UserID      string
	DisplayName string
	Creds       nextcloud.Credentials
	// RevokeOnEnd: the app password was created by the panel (Login Flow v2) and is
	// deleted in Nextcloud when the session ends (logout, expiry, shutdown).
	RevokeOnEnd bool
	Method      string // "flow" | "app-password"
	ClientIP    string
	Created     time.Time
	Expires     time.Time

	mu        sync.Mutex
	lastCheck time.Time
}

// NeedsRecheck reports (and claims) whether the admin membership must be re-verified.
func (s *Session) NeedsRecheck(now time.Time, every time.Duration) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if now.Sub(s.lastCheck) < every {
		return false
	}
	s.lastCheck = now
	return true
}

// CheckCSRF compares the given token with the session token in constant time.
func (s *Session) CheckCSRF(tok string) bool {
	return tok != "" && subtle.ConstantTimeCompare([]byte(tok), []byte(s.CSRF)) == 1
}

// Store keeps sessions in memory. Keys are SHA-256 hashes of the cookie value.
type Store struct {
	mu       sync.Mutex
	sessions map[string]*Session
	ttl      time.Duration
	max      int
	now      func() time.Time
	// OnEnd is called (outside the lock, in a goroutine) whenever a session ends.
	OnEnd func(*Session)
}

// NewStore creates a session store.
func NewStore(ttl time.Duration, max int) *Store {
	return &Store{sessions: map[string]*Session{}, ttl: ttl, max: max, now: time.Now}
}

// RandomToken returns n random bytes, base64url encoded.
func RandomToken(n int) string {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic(err) // crypto/rand never fails on supported platforms
	}
	return base64.RawURLEncoding.EncodeToString(b)
}

func key(id string) string {
	h := sha256.Sum256([]byte(id))
	return hex.EncodeToString(h[:])
}

// Create stores a new session and returns it. When the store is full the oldest session is evicted.
func (st *Store) Create(userID, displayName string, cr nextcloud.Credentials, revoke bool, method, ip string) *Session {
	now := st.now()
	s := &Session{
		ID:          RandomToken(32),
		CSRF:        RandomToken(32),
		UserID:      userID,
		DisplayName: displayName,
		Creds:       cr,
		RevokeOnEnd: revoke,
		Method:      method,
		ClientIP:    ip,
		Created:     now,
		Expires:     now.Add(st.ttl),
		lastCheck:   now,
	}
	var evicted []*Session
	st.mu.Lock()
	evicted = st.sweepLocked(now)
	for len(st.sessions) >= st.max && st.max > 0 {
		var oldestK string
		var oldest *Session
		for k, v := range st.sessions {
			if oldest == nil || v.Created.Before(oldest.Created) {
				oldestK, oldest = k, v
			}
		}
		delete(st.sessions, oldestK)
		evicted = append(evicted, oldest)
	}
	st.sessions[key(s.ID)] = s
	st.mu.Unlock()
	st.ended(evicted)
	return s
}

// Get returns the live session for a cookie value, or nil.
func (st *Store) Get(id string) *Session {
	if id == "" {
		return nil
	}
	k := key(id)
	now := st.now()
	st.mu.Lock()
	s, ok := st.sessions[k]
	if ok && now.After(s.Expires) {
		delete(st.sessions, k)
		st.mu.Unlock()
		st.ended([]*Session{s})
		return nil
	}
	st.mu.Unlock()
	if !ok {
		return nil
	}
	return s
}

// Delete removes a session (logout) and triggers OnEnd.
func (st *Store) Delete(id string) *Session {
	k := key(id)
	st.mu.Lock()
	s, ok := st.sessions[k]
	delete(st.sessions, k)
	st.mu.Unlock()
	if !ok {
		return nil
	}
	st.ended([]*Session{s})
	return s
}

// DeleteUser removes every session of a user (e.g. admin rights revoked).
func (st *Store) DeleteUser(userID string) {
	var gone []*Session
	st.mu.Lock()
	for k, s := range st.sessions {
		if s.UserID == userID {
			delete(st.sessions, k)
			gone = append(gone, s)
		}
	}
	st.mu.Unlock()
	st.ended(gone)
}

// Sweep removes expired sessions.
func (st *Store) Sweep() {
	st.mu.Lock()
	gone := st.sweepLocked(st.now())
	st.mu.Unlock()
	st.ended(gone)
}

// DrainAll removes all sessions and returns them without calling OnEnd (used at shutdown).
func (st *Store) DrainAll() []*Session {
	st.mu.Lock()
	defer st.mu.Unlock()
	out := make([]*Session, 0, len(st.sessions))
	for k, s := range st.sessions {
		out = append(out, s)
		delete(st.sessions, k)
	}
	return out
}

// Count returns the number of live sessions.
func (st *Store) Count() int {
	st.mu.Lock()
	defer st.mu.Unlock()
	return len(st.sessions)
}

func (st *Store) sweepLocked(now time.Time) []*Session {
	var gone []*Session
	for k, s := range st.sessions {
		if now.After(s.Expires) {
			delete(st.sessions, k)
			gone = append(gone, s)
		}
	}
	return gone
}

func (st *Store) ended(ss []*Session) {
	if st.OnEnd == nil {
		return
	}
	for _, s := range ss {
		if s != nil {
			go st.OnEnd(s)
		}
	}
}
