//! Safe Rust bindings for the duktape-c3 JavaScript engine.
//!
//! ```no_run
//! use jse::{Kind, Runtime};
//!
//! # fn main() -> Result<(), jse::Error> {
//! let rt = Runtime::new()?;
//!
//! let v = rt.eval("[1, 2, 3].reduce((a, b) => a + b)")?;
//! assert_eq!(v.as_number()?, 6.0);
//!
//! match rt.eval("throw new TypeError('nope')") {
//!     Err(e) if e.kind() == Kind::Throw => println!("caught: {}", e.message()),
//!     _ => unreachable!(),
//! }
//! // `rt` and every Value drop here.
//! # Ok(())
//! # }
//! ```
//!
//! # What this layer guarantees
//!
//! - No raw pointer or raw handle is ever handed to the caller. A [`Value`]
//!   borrows its [`Runtime`], so the borrow checker rejects a value outliving
//!   the runtime that owns it — the case the C ABI leaves to discipline.
//! - Slots are released on [`Drop`], so the 1024-slot registry cannot be leaked
//!   into exhaustion by ordinary use.
//! - Every fallible call returns [`Result`], with the engine's message
//!   captured (copied, not borrowed) into [`Error`].
//! - [`Runtime`] is neither [`Send`] nor [`Sync`]: the ABI is documented as
//!   not thread-safe and does not lock, so this is enforced at compile time
//!   rather than by convention.
//!
//! # Not covered
//!
//! Registering a Rust callback as a JS function is impossible in the current
//! engine — built-in dispatch is an index into a table sized and filled at
//! compile time, never a host pointer. Calling a JS function from Rust is
//! likewise absent from the v1 C ABI; wrap the call in a JS snippet and use
//! [`Runtime::eval`] instead.

use std::ffi::{CStr, CString};
use std::fmt;
use std::marker::PhantomData;
use std::os::raw::{c_char, c_int};
use std::sync::atomic::{AtomicBool, Ordering};

use jse_sys as sys;

/// Why a call failed.
///
/// [`Kind::Syntax`] and [`Kind::Throw`] carry the engine's own message; the
/// rest are structural faults from the binding layer.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    /// Allocation failed inside the engine.
    OutOfMemory,
    /// The source did not compile.
    Syntax,
    /// The script threw and nothing caught it.
    Throw,
    /// Engine fault with no JS error attached.
    Internal,
    /// Bad argument or a handle the engine does not recognise.
    Invalid,
    /// The value is not of the requested type. No coercion is performed.
    Type,
    /// The 1024-slot value registry is exhausted.
    Full,
    /// A runtime already exists in this process.
    AlreadyOpen,
    /// Source or a string result was not valid UTF-8 / contained a NUL byte.
    Encoding,
    /// The ABI returned a status this binding does not know.
    Unknown(c_int),
}

impl Kind {
    fn from_status(status: c_int) -> Self {
        match status {
            sys::JSE_ERR_NOMEM => Kind::OutOfMemory,
            sys::JSE_ERR_SYNTAX => Kind::Syntax,
            sys::JSE_ERR_THROW => Kind::Throw,
            sys::JSE_ERR_INTERNAL => Kind::Internal,
            sys::JSE_ERR_INVALID => Kind::Invalid,
            sys::JSE_ERR_TYPE => Kind::Type,
            sys::JSE_ERR_FULL => Kind::Full,
            other => Kind::Unknown(other),
        }
    }

    fn describe(self) -> &'static str {
        match self {
            Kind::OutOfMemory => "out of memory",
            Kind::Syntax => "syntax error",
            Kind::Throw => "uncaught exception",
            Kind::Internal => "internal engine error",
            Kind::Invalid => "invalid argument",
            Kind::Type => "wrong type",
            Kind::Full => "value registry full",
            Kind::AlreadyOpen => "a runtime is already open in this process",
            Kind::Encoding => "invalid text encoding",
            Kind::Unknown(_) => "unknown error",
        }
    }
}

/// A failed engine call, with the engine's message where it had one.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Error {
    kind: Kind,
    message: String,
}

impl Error {
    fn new(kind: Kind, message: impl Into<String>) -> Self {
        Error {
            kind,
            message: message.into(),
        }
    }

    /// Structured cause, for matching.
    pub fn kind(&self) -> Kind {
        self.kind
    }

    /// The engine's message, or a description of the structural fault.
    pub fn message(&self) -> &str {
        &self.message
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.message.is_empty() {
            f.write_str(self.kind.describe())
        } else {
            write!(f, "{}: {}", self.kind.describe(), self.message)
        }
    }
}

impl std::error::Error for Error {}

/// The JavaScript type of a [`Value`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Type {
    Undefined,
    Null,
    Boolean,
    Number,
    String,
    Object,
    Function,
    /// Symbol, BigInt, and anything else the ABI does not name.
    Other,
}

impl Type {
    fn from_raw(raw: c_int) -> Self {
        match raw {
            sys::JSE_TYPE_NULL => Type::Null,
            sys::JSE_TYPE_BOOLEAN => Type::Boolean,
            sys::JSE_TYPE_NUMBER => Type::Number,
            sys::JSE_TYPE_STRING => Type::String,
            sys::JSE_TYPE_OBJECT => Type::Object,
            sys::JSE_TYPE_FUNCTION => Type::Function,
            sys::JSE_TYPE_OTHER => Type::Other,
            // JSE_TYPE_UNDEFINED, and anything unrecognised, which the ABI
            // also reports as undefined.
            _ => Type::Undefined,
        }
    }
}

/// Guards the ABI's one-runtime-per-process rule so a second [`Runtime::new`]
/// reports [`Kind::AlreadyOpen`] instead of racing inside C.
static RUNTIME_OPEN: AtomicBool = AtomicBool::new(false);

/// The engine. Owns the heap and every value derived from it.
///
/// Dropping it closes the engine and frees the heap. Values borrow it, so no
/// [`Value`] can still be alive at that point.
pub struct Runtime {
    raw: sys::jse_runtime,
    /// The ABI is not thread-safe; keep this type off other threads.
    _not_send_sync: PhantomData<*const ()>,
}

impl Runtime {
    /// Open the engine.
    ///
    /// Only one runtime may exist per process — the engine keeps process-global
    /// state — so a second call while one is alive fails with
    /// [`Kind::AlreadyOpen`].
    pub fn new() -> Result<Self, Error> {
        if RUNTIME_OPEN.swap(true, Ordering::SeqCst) {
            return Err(Error::new(Kind::AlreadyOpen, ""));
        }

        let mut raw: sys::jse_runtime = std::ptr::null_mut();
        // SAFETY: `raw` is a valid, writable out-parameter.
        let status = unsafe { sys::jse_open(&mut raw) };

        if status != sys::JSE_OK || raw.is_null() {
            RUNTIME_OPEN.store(false, Ordering::SeqCst);
            return Err(Error::new(Kind::from_status(status), ""));
        }

        Ok(Runtime {
            raw,
            _not_send_sync: PhantomData,
        })
    }

    /// The engine version, `"MAJOR.MINOR.PATCH"`.
    pub fn version() -> &'static str {
        // SAFETY: jse_version returns a static, NUL-terminated string and is
        // documented never to return null.
        let s = unsafe { CStr::from_ptr(sys::jse_version()) };
        s.to_str().unwrap_or("unknown")
    }

    /// Compile and run `src`, yielding its completion value — so `"40 + 2"`
    /// evaluates to `42`, matching `eval()` semantics.
    ///
    /// Pending promise jobs are drained before this returns.
    pub fn eval(&self, src: &str) -> Result<Value<'_>, Error> {
        let mut handle: sys::jse_value = sys::JSE_INVALID_VALUE;
        // The ABI takes a pointer plus an explicit length, so interior NULs
        // are fine and no CString round-trip is needed.
        // SAFETY: `src` is a valid slice for `src.len()` bytes; `handle` is a
        // valid out-parameter; `self.raw` is a live runtime.
        let status = unsafe {
            sys::jse_eval(
                self.raw,
                src.as_ptr() as *const c_char,
                src.len(),
                &mut handle,
            )
        };

        if status != sys::JSE_OK {
            return Err(self.error(status));
        }

        Ok(Value {
            rt: self,
            handle,
        })
    }

    /// Run `src` purely for its side effects, discarding the result.
    pub fn eval_unit(&self, src: &str) -> Result<(), Error> {
        // SAFETY: as `eval`, but with a null out-parameter, which the ABI
        // documents as "run for side effects".
        let status = unsafe {
            sys::jse_eval(
                self.raw,
                src.as_ptr() as *const c_char,
                src.len(),
                std::ptr::null_mut(),
            )
        };

        if status != sys::JSE_OK {
            return Err(self.error(status));
        }
        Ok(())
    }

    /// Run pending promise jobs. [`Runtime::eval`] already drains before it
    /// returns; this is for the case where host code resolved a promise.
    pub fn drain_microtasks(&self) {
        // SAFETY: `self.raw` is a live runtime; the ABI guards re-entrancy.
        unsafe { sys::jse_drain_microtasks(self.raw) }
    }

    /// Build an [`Error`] from a status, copying the engine's message out
    /// before the next call can clobber it.
    fn error(&self, status: c_int) -> Error {
        // SAFETY: jse_last_error is documented never to return null, and its
        // buffer is valid until the next jse_* call. We copy immediately.
        let msg = unsafe {
            let p = sys::jse_last_error(self.raw);
            if p.is_null() {
                String::new()
            } else {
                CStr::from_ptr(p).to_string_lossy().into_owned()
            }
        };
        Error::new(Kind::from_status(status), msg)
    }
}

impl fmt::Debug for Runtime {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        // The raw pointer is deliberately not printed: it is an engine
        // internal and nothing outside this crate should act on it.
        f.debug_struct("Runtime")
            .field("version", &Runtime::version())
            .finish_non_exhaustive()
    }
}

impl Drop for Runtime {
    fn drop(&mut self) {
        // SAFETY: `self.raw` came from a successful jse_open and is closed
        // exactly once, since Runtime is neither Copy nor Clone. Every Value
        // borrows self, so none can be alive here.
        unsafe { sys::jse_close(self.raw) };
        RUNTIME_OPEN.store(false, Ordering::SeqCst);
    }
}

/// A JavaScript value, owned by the caller and released on [`Drop`].
///
/// The `'rt` lifetime ties it to its [`Runtime`], so a value cannot outlive the
/// engine that produced it.
pub struct Value<'rt> {
    rt: &'rt Runtime,
    handle: sys::jse_value,
}

impl<'rt> Value<'rt> {
    /// The value's JavaScript type. Cannot fail.
    pub fn type_of(&self) -> Type {
        // SAFETY: live runtime, live handle; the ABI reports undefined for
        // anything it does not recognise rather than faulting.
        Type::from_raw(unsafe { sys::jse_type_of(self.rt.raw, self.handle) })
    }

    /// Read a number. Does not coerce: a non-number is [`Kind::Type`].
    pub fn as_number(&self) -> Result<f64, Error> {
        let mut out = 0.0f64;
        // SAFETY: live runtime and handle; `out` is a valid out-parameter.
        let status = unsafe { sys::jse_get_number(self.rt.raw, self.handle, &mut out) };
        if status != sys::JSE_OK {
            return Err(self.rt.error(status));
        }
        Ok(out)
    }

    /// Read a boolean. Does not coerce: a non-boolean is [`Kind::Type`].
    pub fn as_bool(&self) -> Result<bool, Error> {
        let mut out: c_int = 0;
        // SAFETY: live runtime and handle; `out` is a valid out-parameter.
        let status = unsafe { sys::jse_get_bool(self.rt.raw, self.handle, &mut out) };
        if status != sys::JSE_OK {
            return Err(self.rt.error(status));
        }
        Ok(out != 0)
    }

    /// Copy a string out as a Rust `String`. Does not coerce: call `String(x)`
    /// in JS first if you want stringification.
    ///
    /// This drives the ABI's measure-then-fill protocol, so no allocation
    /// crosses the boundary in either direction.
    pub fn as_string(&self) -> Result<String, Error> {
        let mut len: usize = 0;

        // Measure. A null buffer asks for the byte length, excluding the NUL.
        // SAFETY: live runtime and handle; null buf with cap 0 is the ABI's
        // documented measuring call.
        let status = unsafe {
            sys::jse_get_string(self.rt.raw, self.handle, std::ptr::null_mut(), 0, &mut len)
        };
        if status != sys::JSE_OK {
            return Err(self.rt.error(status));
        }

        // Fill. The ABI writes a trailing NUL, so ask for len + 1.
        let mut buf = vec![0u8; len + 1];
        // SAFETY: `buf` has capacity len + 1, exactly what the ABI requires,
        // and it writes at most that many bytes.
        let status = unsafe {
            sys::jse_get_string(
                self.rt.raw,
                self.handle,
                buf.as_mut_ptr() as *mut c_char,
                buf.len(),
                &mut len,
            )
        };
        if status != sys::JSE_OK {
            return Err(self.rt.error(status));
        }

        buf.truncate(len);
        String::from_utf8(buf).map_err(|_| {
            Error::new(Kind::Encoding, "engine returned a non-UTF-8 string")
        })
    }

    /// Render a primitive the way JS would display it.
    ///
    /// The v1 ABI has no coercion entry point and no way to pass a handle back
    /// into a script, so this covers only the primitives that can be read
    /// directly. For objects, arrays, and functions, call `String(x)` or
    /// `JSON.stringify(x)` inside the snippet you evaluate.
    pub fn to_display_string(&self) -> Result<String, Error> {
        match self.type_of() {
            Type::String => self.as_string(),
            Type::Number => Ok(format_number(self.as_number()?)),
            Type::Boolean => Ok(self.as_bool()?.to_string()),
            Type::Null => Ok("null".to_string()),
            Type::Undefined => Ok("undefined".to_string()),
            _ => Err(Error::new(
                Kind::Type,
                "no ABI coercion for this type; wrap it in String(...) in JS",
            )),
        }
    }
}

impl Drop for Value<'_> {
    fn drop(&mut self) {
        // SAFETY: live runtime; the ABI accepts 0 and already-freed handles,
        // and Value is not Copy/Clone, so this frees exactly once.
        unsafe { sys::jse_value_free(self.rt.raw, self.handle) };
    }
}

impl fmt::Debug for Value<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "Value({:?})", self.type_of())
    }
}

/// Render a number the way JS does: integral values without a trailing `.0`.
fn format_number(n: f64) -> String {
    if n.is_finite() && n.fract() == 0.0 && n.abs() < 1e21 {
        format!("{}", n as i64)
    } else {
        format!("{}", n)
    }
}

/// Convert a Rust string into a `CString`, rejecting interior NULs.
///
/// Not needed by [`Runtime::eval`], which passes an explicit length, but
/// exported for callers building source out of untrusted fragments.
pub fn to_c_source(src: &str) -> Result<CString, Error> {
    CString::new(src).map_err(|_| Error::new(Kind::Encoding, "source contains a NUL byte"))
}
