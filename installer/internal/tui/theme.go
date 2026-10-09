package tui

import "charm.land/lipgloss/v2"

// Styles is the Serpantinum palette. The 16-colour variant (Linux VT) uses
// the ANSI colours that the console palette (\e]P...) maps to the same hues.
type Styles struct {
	Text, Dim, Accent, AccentB, Pink, OK, Warn, Bad           lipgloss.Style
	Sel, Pill, PillCap, Key, Title, Border, BorderFocus, Code lipgloss.Style
}

func fg(c string) lipgloss.Style { return lipgloss.NewStyle().Foreground(lipgloss.Color(c)) }

// NewStyles returns the palette for 16 (VT) or full colours.
func NewStyles(sixteen bool) Styles {
	if sixteen {
		return Styles{
			Text: lipgloss.NewStyle(), Dim: fg("8"), Accent: fg("13"), AccentB: fg("13").Bold(true),
			Pink: fg("9"), OK: fg("10"), Warn: fg("11"), Bad: fg("1"),
			Sel:     lipgloss.NewStyle().Background(lipgloss.Color("5")).Foreground(lipgloss.Color("15")).Bold(true),
			Pill:    lipgloss.NewStyle().Background(lipgloss.Color("13")).Foreground(lipgloss.Color("0")).Bold(true),
			PillCap: fg("13"), Key: fg("13").Bold(true), Title: fg("13").Bold(true), Border: fg("8"), BorderFocus: fg("13"), Code: fg("9"),
		}
	}
	return Styles{
		Text: fg("#e6e1ee"), Dim: fg("#7a7690"), Accent: fg("#c8b6ff"), AccentB: fg("#c8b6ff").Bold(true),
		Pink: fg("#f4b8c8"), OK: fg("#a6e3a1"), Warn: fg("#f9e2af"), Bad: fg("#f38ba8"),
		Sel:     lipgloss.NewStyle().Background(lipgloss.Color("#4a3f7a")).Foreground(lipgloss.Color("#ffffff")).Bold(true),
		Pill:    lipgloss.NewStyle().Background(lipgloss.Color("#c8b6ff")).Foreground(lipgloss.Color("#1b1626")).Bold(true),
		PillCap: fg("#c8b6ff"),
		Key:     lipgloss.NewStyle().Background(lipgloss.Color("#2b2740")).Foreground(lipgloss.Color("#c8b6ff")).Bold(true),
		Title:   fg("#c8b6ff").Bold(true), Border: fg("#4b4763"), BorderFocus: fg("#c8b6ff"), Code: fg("#f4b8c8"),
	}
}
