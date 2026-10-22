package httpapi_test

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"fin-ai-advisor/portfolio-api/internal/engine"
	"fin-ai-advisor/portfolio-api/internal/httpapi"
	"fin-ai-advisor/portfolio-api/internal/orders"
	"fin-ai-advisor/portfolio-api/internal/store"
)

func newServer(t *testing.T) *httptest.Server {
	t.Helper()
	repo, err := store.Open(context.Background(), filepath.Join(t.TempDir(), "api.db"))
	if err != nil {
		t.Fatal(err)
	}
	pool, _ := engine.NewWorkerPool(2, 50, 2)
	pool.Start(context.Background())

	srv := httptest.NewServer(httpapi.New(orders.NewService(repo, pool, 100), repo, pool).Routes())
	t.Cleanup(func() {
		srv.Close()
		_ = pool.Shutdown(2 * time.Second)
		_ = repo.Close()
	})
	return srv
}

func post(t *testing.T, srv *httptest.Server, body, idemKey string) (*http.Response, map[string]any) {
	t.Helper()
	req, _ := http.NewRequest(http.MethodPost, srv.URL+"/api/v1/orders/buy", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	if idemKey != "" {
		req.Header.Set("Idempotency-Key", idemKey)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var out map[string]any
	_ = json.NewDecoder(resp.Body).Decode(&out)
	return resp, out
}

func get(t *testing.T, srv *httptest.Server, path string) (int, map[string]any) {
	t.Helper()
	resp, err := http.Get(srv.URL + path)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var out map[string]any
	_ = json.NewDecoder(resp.Body).Decode(&out)
	return resp.StatusCode, out
}

const validOrder = `{"portfolio_id":"port-9","symbol":"AAPL","quantity":10,"price":"185.50"}`

func TestPlaceOrder_AcceptedThenIdempotentReplay(t *testing.T) {
	srv := newServer(t)

	resp, body := post(t, srv, validOrder, "idem-123")
	if resp.StatusCode != http.StatusAccepted {
		t.Fatalf("expected 202, got %d: %v", resp.StatusCode, body)
	}
	order := body["order"].(map[string]any)
	if order["total"] != "1855.00" || resp.Header.Get("Location") == "" {
		t.Fatalf("unexpected response: %v", body)
	}

	replay, replayBody := post(t, srv, validOrder, "idem-123")
	if replay.StatusCode != http.StatusOK || replayBody["dispatch"] != orders.DispatchReplay {
		t.Fatalf("retry: expected 200/replay, got %d %v", replay.StatusCode, replayBody)
	}
	if replayBody["order"].(map[string]any)["id"] != order["id"] {
		t.Fatal("the retry must return the same order")
	}
}

func TestPlaceOrder_RejectsBadInput(t *testing.T) {
	srv := newServer(t)
	cases := map[string]string{
		"malformed json":   `{"portfolio_id":`,
		"unknown field":    `{"portfolio_id":"p","symbol":"A","quantity":1,"price":"1.00","hack":true}`,
		"price as float":   `{"portfolio_id":"p","symbol":"A","quantity":1,"price":185.5}`,
		"price 3 decimals": `{"portfolio_id":"p","symbol":"A","quantity":1,"price":"1.005"}`,
		"zero quantity":    `{"portfolio_id":"p","symbol":"A","quantity":0,"price":"1.00"}`,
	}
	for name, body := range cases {
		if resp, out := post(t, srv, body, ""); resp.StatusCode != http.StatusBadRequest {
			t.Errorf("%s: expected 400, got %d %v", name, resp.StatusCode, out)
		}
	}
}

func TestGetOrderAndPositions(t *testing.T) {
	srv := newServer(t)
	_, body := post(t, srv, validOrder, "idem-get")
	id := body["order"].(map[string]any)["id"].(string)

	deadline := time.Now().Add(3 * time.Second)
	for {
		status, out := get(t, srv, "/api/v1/orders/"+id)
		if status != http.StatusOK {
			t.Fatalf("GET order: %d", status)
		}
		if out["order"].(map[string]any)["status"] == store.StatusExecuted {
			if n := len(out["ledger"].([]any)); n != 2 {
				t.Fatalf("expected 2 ledger entries, got %d", n)
			}
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("the order was not executed in time: %v", out)
		}
		time.Sleep(20 * time.Millisecond)
	}

	status, out := get(t, srv, "/api/v1/portfolios/port-9/positions")
	if status != http.StatusOK {
		t.Fatalf("GET positions: %d", status)
	}
	positions, _ := json.Marshal(out["positions"])
	if string(positions) != `[{"amount":"10","asset":"AAPL"},{"amount":"-1855.00","asset":"USD"}]` {
		t.Fatalf("unexpected positions: %s", positions)
	}

	if status, _ := get(t, srv, "/api/v1/orders/does-not-exist"); status != http.StatusNotFound {
		t.Fatalf("expected 404, got %d", status)
	}
}

func TestHealth(t *testing.T) {
	srv := newServer(t)
	if status, out := get(t, srv, "/health"); status != http.StatusOK || out["status"] != "UP" {
		t.Fatalf("health: %d %v", status, out)
	}
}
