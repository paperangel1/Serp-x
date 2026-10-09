.pragma library

// Shell command line of a «run this command» hotkey. Hyprland hands exec_cmd strings to /bin/sh, and x_keybinds.sh escapes the
// string for Lua (lua_str), so the only job left is POSIX shell quoting: a single-quoted word passes every character
// (spaces, double quotes, $, backticks, backslashes, unicode) unchanged, a single quote is written as '\''.
function shQuote(s) {
    return "'" + String(s).replace(/'/g, "'\\''") + "'";
}

// `serpantinum run 'Name'`; names that start with "-" go after "--" so the CLI does not read them as options.
function runLine(name) {
    var n = String(name);
    return "serpantinum run " + (n.charAt(0) === "-" ? "-- " : "") + shQuote(n);
}
