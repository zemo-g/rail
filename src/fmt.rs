/// Rail formatter — `rail fmt`
/// Normalizes indentation (2 spaces), trailing whitespace, blank lines between top-level defs.

/// Format a Rail source file.
pub fn format_source(source: &str) -> String {
    let mut lines: Vec<String> = source.lines().map(|l| l.to_string()).collect();

    // Pass 1: Normalize indentation to 2 spaces per level
    for line in &mut lines {
        let trimmed = line.trim_start();
        if trimmed.is_empty() {
            *line = String::new();
            continue;
        }

        // Count existing indentation
        let indent_chars = line.len() - trimmed.len();
        let leading = &line[..indent_chars];

        // Detect indent level: each tab = 1 level, each 2+ spaces = 1 level
        let level = if leading.contains('\t') {
            leading.chars().filter(|c| *c == '\t').count()
        } else {
            // Count spaces, normalize to 2-space levels
            let spaces = leading.len();
            // Round to nearest 2-space level
            (spaces + 1) / 2
        };

        *line = format!("{}{}", "  ".repeat(level), trimmed);
    }

    // Pass 2: Strip trailing whitespace
    for line in &mut lines {
        let trimmed = line.trim_end();
        *line = trimmed.to_string();
    }

    // Pass 3: Ensure exactly one blank line between top-level declarations
    let mut result = Vec::new();
    let mut prev_was_blank = false;
    let mut _prev_was_toplevel_end = false;

    for (i, line) in lines.iter().enumerate() {
        let is_blank = line.is_empty();
        let is_toplevel_start = !is_blank && !line.starts_with(' ') && !line.starts_with("--");

        // Insert blank line before top-level declarations (except the first)
        if is_toplevel_start && i > 0 && !prev_was_blank && !result.is_empty() {
            result.push(String::new());
        }

        // Collapse multiple blank lines into one
        if is_blank && prev_was_blank {
            continue;
        }

        result.push(line.clone());
        prev_was_blank = is_blank;
        _prev_was_toplevel_end = !is_blank && !line.starts_with(' ');
    }

    // Pass 4: Ensure file ends with a single newline
    while result.last().map(|l| l.is_empty()).unwrap_or(false) {
        result.pop();
    }

    let mut output = result.join("\n");
    output.push('\n');
    output
}

/// Check if a source file is already formatted.
/// Returns true if formatting would produce no changes.
#[allow(dead_code)]
pub fn is_formatted(source: &str) -> bool {
    format_source(source) == source
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_format_basic() {
        let input = "add x y = x + y\n\nmain =\n  let _ = print (add 1 2)\n  0\n";
        let output = format_source(input);
        assert_eq!(output, input);
    }

    #[test]
    fn test_format_trailing_whitespace() {
        let input = "add x y = x + y   \nmain =  \n  0\n";
        let output = format_source(input);
        assert!(!output.contains("   \n"));
        assert!(!output.contains("  \n"));
    }

    #[test]
    fn test_format_multiple_blank_lines() {
        let input = "add x y = x + y\n\n\n\nmain =\n  0\n";
        let output = format_source(input);
        // Should have at most one blank line between declarations
        assert!(!output.contains("\n\n\n"));
    }

    #[test]
    fn test_format_idempotent() {
        let input = "add x y = x + y\n\nmain =\n  let _ = print (add 1 2)\n  0\n";
        let once = format_source(input);
        let twice = format_source(&once);
        assert_eq!(once, twice, "formatter is not idempotent");
    }

    #[test]
    fn test_format_ensures_blank_between_decls() {
        let input = "add x y = x + y\nmain =\n  0\n";
        let output = format_source(input);
        assert!(output.contains("\n\n"), "should add blank line between top-level decls");
    }
}
