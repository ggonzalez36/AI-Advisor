package domain_test

import (
	"testing"

	"fin-ai-advisor/portfolio-api/internal/domain"
)

func TestParseCents(t *testing.T) {
	valid := map[string]int64{
		"185.50": 18550,
		"185.5":  18550,
		"185":    18500,
		"0.01":   1,
		" 42.07": 4207,
	}
	for in, want := range valid {
		got, err := domain.ParseCents(in)
		if err != nil || got != want {
			t.Errorf("ParseCents(%q) = %d, %v; expected %d", in, got, err, want)
		}
	}

	for _, in := range []string{"", "-1.00", "1.234", "abc", "1.", ".5", "1e3", "+3"} {
		if _, err := domain.ParseCents(in); err == nil {
			t.Errorf("ParseCents(%q) should have failed", in)
		}
	}
}

func TestFormatCents(t *testing.T) {
	cases := map[int64]string{18550: "185.50", 1: "0.01", -185500: "-1855.00", 0: "0.00"}
	for in, want := range cases {
		if got := domain.FormatCents(in); got != want {
			t.Errorf("FormatCents(%d) = %q; expected %q", in, got, want)
		}
	}
}
