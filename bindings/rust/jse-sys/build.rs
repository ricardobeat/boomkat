//! Locate the engine's static archive and tell rustc how to link it.
//!
//! Search order:
//!   1. `JSE_LIB_DIR` — a directory holding `libjse.a` (or `jse_static.a`).
//!   2. The in-tree build output, `<repo>/out/jse_static.a`, which is where
//!      `make lib` puts it.
//!
//! The archive already contains the vendored C (libregexp, cutils, dtoa), so
//! nothing else needs compiling here — only the platform libs the engine calls
//! into. On macOS libSystem covers libm/libdl; ELF targets need them named.

use std::env;
use std::path::{Path, PathBuf};

/// `make lib` names the archive `jse_static.a`; `make install` installs it as
/// `libjse.a`. Accept either, and prefer the installed spelling.
const CANDIDATES: [&str; 2] = ["libjse.a", "jse_static.a"];

fn find_archive(dir: &Path) -> Option<PathBuf> {
    CANDIDATES
        .iter()
        .map(|n| dir.join(n))
        .find(|p| p.is_file())
}

/// Walk up from this crate looking for the repo root (the directory holding
/// `include/jse.h`). Works whether the crate sits at `bindings/rust/jse-sys`
/// or has been vendored somewhere shallower.
fn repo_root() -> Option<PathBuf> {
    let start = PathBuf::from(env::var("CARGO_MANIFEST_DIR").ok()?);
    let mut cur = start.as_path();
    loop {
        if cur.join("include/jse.h").is_file() {
            return Some(cur.to_path_buf());
        }
        cur = cur.parent()?;
    }
}

fn main() {
    println!("cargo:rerun-if-env-changed=JSE_LIB_DIR");

    let dir = if let Ok(d) = env::var("JSE_LIB_DIR") {
        let d = PathBuf::from(d);
        if find_archive(&d).is_none() {
            panic!(
                "JSE_LIB_DIR={} contains neither libjse.a nor jse_static.a",
                d.display()
            );
        }
        d
    } else {
        let root = repo_root().expect(
            "could not locate the duktape-c3 checkout (no ancestor directory \
             contains include/jse.h). Set JSE_LIB_DIR to a directory holding \
             libjse.a or jse_static.a.",
        );
        let out = root.join("out");
        if find_archive(&out).is_none() {
            panic!(
                "no engine archive at {}. Build it first:\n\n    make -C {} lib\n",
                out.display(),
                root.display()
            );
        }
        out
    };

    let archive = find_archive(&dir).expect("checked above");
    println!("cargo:rerun-if-changed={}", archive.display());

    // `-l static=jse` needs a `lib`-prefixed file. `make lib` emits
    // `jse_static.a`, which does not match, and `cargo:rustc-link-arg` would
    // not do here: link-args apply only to the crate currently being built,
    // not to the downstream binaries and examples that actually reference
    // these symbols. So normalise the name by copying into OUT_DIR and link it
    // as an ordinary static library, which *is* propagated transitively.
    let search_dir = if archive.file_name().unwrap() == "libjse.a" {
        dir.clone()
    } else {
        let out_dir = PathBuf::from(env::var("OUT_DIR").expect("cargo sets OUT_DIR"));
        let staged = out_dir.join("libjse.a");
        std::fs::copy(&archive, &staged).unwrap_or_else(|e| {
            panic!(
                "could not stage {} as {}: {e}",
                archive.display(),
                staged.display()
            )
        });
        out_dir
    };

    println!("cargo:rustc-link-search=native={}", search_dir.display());
    println!("cargo:rustc-link-lib=static=jse");

    // Platform libraries the engine itself depends on.
    let target_os = env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    if target_os != "macos" && target_os != "ios" {
        println!("cargo:rustc-link-lib=dylib=m");
        println!("cargo:rustc-link-lib=dylib=dl");
    }

    // Downstream crates can read this as DEP_JSE_LIB_DIR.
    println!("cargo:lib_dir={}", search_dir.display());
}
