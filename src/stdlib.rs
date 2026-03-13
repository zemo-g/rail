/// Embedded standard library modules.
/// These are compiled into the binary so Rail programs can import them
/// without needing external files on disk.

pub const PRELUDE: &str = include_str!("../stdlib/prelude.rail");
pub const MATH: &str = include_str!("../stdlib/math.rail");
pub const STRING: &str = include_str!("../stdlib/string.rail");

/// Map a module name to its embedded source, if it's a stdlib module.
pub fn get_embedded(name: &str) -> Option<&'static str> {
    match name {
        "Prelude" => Some(PRELUDE),
        "Math" => Some(MATH),
        "String" => Some(STRING),
        _ => None,
    }
}

/// List all available stdlib module names.
pub fn list_modules() -> &'static [&'static str] {
    &["Prelude", "Math", "String"]
}
