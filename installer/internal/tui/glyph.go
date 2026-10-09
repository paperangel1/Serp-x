package tui

// Glyph modes (plan, stage 5): nerd uses the Powerline round caps U+E0B6 /
// U+E0B4 for pills, unicode uses rounded box-drawing, ascii is the bare Linux
// console: square CP437 corners, 16 colours, nothing outside the VT font.
const (
	GlyphNerd    = "nerd"
	GlyphUnicode = "unicode"
	GlyphASCII   = "ascii"
)

// Glyphs is the set of characters of one mode.
type Glyphs struct {
	Mode                              string
	TL, TR, BL, BR, H, V              string
	CapL, CapR                        string // pill caps ("" = none)
	Check, Cross, Warn, Skip          string
	Empty, Full, Resume               string // list markers
	Radio, RadioOff                   string
	Box, BoxOff, BoxPart              string
	Diamond, Arrow, Back, Sep, Bullet string
	Cursor                            string
	Mask                              string
	Spinner                           []string
	BarFull, BarEmpty                 string
	BarPart                           []string // 1/8 .. 7/8 blocks, nil = none
	Updown                            string
	Tree                              string
}

// GlyphsFor returns the set for a mode ("" = unicode).
func GlyphsFor(mode string) Glyphs {
	base := Glyphs{
		Mode: GlyphUnicode,
		TL:   "╭", TR: "╮", BL: "╰", BR: "╯", H: "─", V: "│",
		Check: "✓", Cross: "✗", Warn: "!", Skip: "–",
		Empty: "○", Full: "●", Resume: "↻",
		Radio: "◉", RadioOff: "○",
		Box: "[✓]", BoxOff: "[ ]", BoxPart: "[■]",
		Diamond: "◆", Arrow: "→", Back: "←", Sep: "─", Bullet: "·",
		Cursor: "▏", Mask: "•",
		Spinner: []string{"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"},
		BarFull: "█", BarEmpty: "░",
		BarPart: []string{"▏", "▎", "▍", "▌", "▋", "▊", "▉"},
		Updown:  "↑↓", Tree: "└",
	}
	switch mode {
	case GlyphNerd:
		base.Mode = GlyphNerd
		base.CapL, base.CapR = "", ""
	case GlyphASCII:
		base.Mode = GlyphASCII
		base.TL, base.TR, base.BL, base.BR, base.H, base.V = "┌", "┐", "└", "┘", "─", "│"
		base.Check, base.Cross, base.Warn, base.Skip = "+", "x", "!", "-"
		base.Empty, base.Full, base.Resume = "o", "*", "~"
		base.Radio, base.RadioOff = "(*)", "( )"
		base.Box, base.BoxOff, base.BoxPart = "[x]", "[ ]", "[#]"
		base.Diamond, base.Arrow, base.Back, base.Sep, base.Bullet = "*", "->", "<-", "-", "-"
		base.Cursor, base.Mask = "_", "*"
		base.Spinner = []string{"|", "/", "-", "\\"}
		base.BarFull, base.BarEmpty = "█", "░"
		base.BarPart = nil
		base.Updown, base.Tree = "^v", "`"
	default:
		base.Mode = GlyphUnicode
	}
	return base
}
