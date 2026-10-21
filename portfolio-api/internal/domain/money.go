package domain

import (
	"errors"
	"fmt"
	"strconv"
	"strings"
)

// ErrInvalidAmount indica un monto decimal mal formado.
var ErrInvalidAmount = errors.New("monto inválido: se espera un decimal con hasta 2 cifras, p. ej. \"185.50\"")

// ParseCents convierte un monto decimal en texto ("185.5", "185.50", "185") a centavos
// sin pasar por float64, evitando errores de representación binaria (0.1 + 0.2 != 0.3).
func ParseCents(s string) (int64, error) {
	s = strings.TrimSpace(s)
	if s == "" || strings.HasPrefix(s, "-") || strings.HasPrefix(s, "+") {
		return 0, ErrInvalidAmount
	}

	whole, frac, hasDot := strings.Cut(s, ".")
	if whole == "" || (hasDot && (frac == "" || len(frac) > 2)) {
		return 0, ErrInvalidAmount
	}
	for len(frac) < 2 {
		frac += "0"
	}

	units, err := strconv.ParseInt(whole, 10, 64)
	if err != nil {
		return 0, ErrInvalidAmount
	}
	cents, err := strconv.ParseInt(frac, 10, 64)
	if err != nil {
		return 0, ErrInvalidAmount
	}
	return units*100 + cents, nil
}

// FormatCents convierte centavos a su representación decimal ("18550" -> "185.50").
func FormatCents(cents int64) string {
	sign := ""
	if cents < 0 {
		sign = "-"
		cents = -cents
	}
	return fmt.Sprintf("%s%d.%02d", sign, cents/100, cents%100)
}
