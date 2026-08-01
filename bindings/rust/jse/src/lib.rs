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
//! - Slots are released on [`Drop`], so the value registry cannot be leaked
//!   into exhaustion by ordinary use.
//! - Every fallible call returns [`Result`], with the engine's message
//!   captured (copied, not borrowed) into [`Error`].
//! - [`Runtime`] is neither [`Send`] nor [`Sync`]: the ABI is documented as
//!   not thread-safe and does not lock, so this is enforced at compile time
//!   rather than by convention.
//!
//! # Host functions
//!
//! [`Runtime::register_fn`] binds a Rust closure as a JS global:
//!
//! ```no_run
//! # fn main() -> Result<(), jse::Error> {
//! # let rt = jse::Runtime::new()?;
//! rt.register_fn("add", 2, |ctx| Ok(ctx.number(ctx.arg(0).as_number()? + ctx.arg(1).as_number()?)))?;
//! assert_eq!(rt.eval("add(40, 2)")?.as_number()?, 42.0);
//! # Ok(())
//! # }
//! ```
//!
//! Returning `Err` from the closure throws in JS, and a panic is caught at the
//! boundary and converted to a throw rather than unwinding into C. See
//! [`Runtime::register_fn`] for both, and for why the closure is leaked.
//!
//! # Not covered
//!
//! There is no way to call a JS function from *outside* a host callback: the
//! ABI's [`Ctx::call`] needs a live call context. Wrap such a call in a JS
//! snippet and use [`Runtime::eval`] instead.

use std::any::Any;
use std::ffi::{CStr, CString};
use std::fmt;
use std::marker::PhantomData;
use std::os::raw::{c_char, c_int, c_void};
use std::panic::{catch_unwind, AssertUnwindSafe};
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
    /// The value registry is exhausted (524287 live handles).
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

    /// A host-function failure that should surface in JS as `new Error(msg)`.
    ///
    /// Returning this from a [`Runtime::register_fn`] closure throws it into
    /// the calling script, where an ordinary `try`/`catch` sees it.
    pub fn throw(message: impl Into<String>) -> Self {
        Error::new(Kind::Throw, message)
    }

    /// The JS error constructor this maps onto when thrown from a host
    /// function. Structural faults become plain `Error`; [`Kind::Type`] and
    /// [`Kind::Syntax`] keep their JS counterpart.
    fn throw_kind(&self) -> c_int {
        match self.kind {
            Kind::Type => sys::JSE_ERROR_TYPE,
            Kind::Syntax => sys::JSE_ERROR_SYNTAX,
            _ => sys::JSE_ERROR,
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

    /// Bind a Rust closure as a JS global function named `name`.
    ///
    /// `arity` becomes the function's `.length`; it does not restrict how many
    /// arguments JS may pass, and [`Ctx::arg`] yields `undefined` past the end
    /// exactly as JS does. The binding is permanent for the runtime's lifetime
    /// and behaves like a built-in everywhere — plain calls, methods,
    /// `.call`/`.apply`/`.bind`, accessors, and callbacks handed to `Array.map`.
    ///
    /// Returning `Err` throws into the calling script; the error's [`Kind`]
    /// picks the JS constructor ([`Error::throw`] for a plain `Error`,
    /// [`Kind::Type`] for a `TypeError`).
    ///
    /// # Lifetime of the closure
    ///
    /// The closure is boxed and **deliberately leaked**. The engine holds a raw
    /// pointer to it for as long as the runtime lives and offers no way to
    /// unregister, so there is no later moment at which dropping it would be
    /// sound. Leaking is the honest encoding of "lives as long as the runtime":
    /// bounded by the number of `register_fn` calls, never per JS call. This is
    /// also why the closure must be `'static` — it may run at any point up to
    /// [`Runtime`] drop, so it cannot borrow anything shorter-lived.
    ///
    /// # Panics
    ///
    /// A panic must never unwind across the C boundary, so the trampoline wraps
    /// every invocation in [`catch_unwind`] and converts a caught panic into a
    /// JS `Error` carrying the panic message. The panic does not propagate to
    /// the caller of [`Runtime::eval`]; the script sees a throw it can catch.
    pub fn register_fn<F>(&self, name: &str, arity: u32, f: F) -> Result<(), Error>
    where
        F: for<'a> Fn(&Ctx<'a>) -> Result<HostValue<'a>, Error> + 'static,
    {
        self.register_fn_impl(name, arity, false, f)
    }

    /// As [`Runtime::register_fn`], but the result may also be called with
    /// `new`.
    ///
    /// On a construct call the engine has already created the instance, which
    /// [`Ctx::this`] sees. Return [`Ctx::undefined`] to keep it, or an object to
    /// replace it, per ES2015 §9.2.2. Without this, `new fn()` throws a
    /// TypeError, matching how built-ins construct only when specified.
    pub fn register_ctor<F>(&self, name: &str, arity: u32, f: F) -> Result<(), Error>
    where
        F: for<'a> Fn(&Ctx<'a>) -> Result<HostValue<'a>, Error> + 'static,
    {
        self.register_fn_impl(name, arity, true, f)
    }

    fn register_fn_impl<F>(
        &self,
        name: &str,
        arity: u32,
        constructable: bool,
        f: F,
    ) -> Result<(), Error>
    where
        F: for<'a> Fn(&Ctx<'a>) -> Result<HostValue<'a>, Error> + 'static,
    {
        // One leaked box per registration; see the doc comment above. The
        // pointer is erased to `*mut c_void` for the ABI and recovered inside
        // `trampoline::<F>`, the only place that knows `F` again.
        //
        // The runtime pointer rides along because the trampoline needs it:
        // `jse_value_free` is a no-op on a null runtime (unlike the readers,
        // which resolve scope handles through the active call), so releasing
        // what `Ctx::call` returns requires the real one.
        let boxed: *mut Registration<F> = Box::into_raw(Box::new(Registration {
            rt: self.raw,
            f,
        }));

        // SAFETY: `name` is valid for `name.len()` bytes; `trampoline::<F>` has
        // the required C signature; `boxed` outlives the runtime because it is
        // never freed. The engine only passes `udata` back, never derefs it.
        let status = unsafe {
            sys::jse_register_fn(
                self.raw,
                name.as_ptr() as *const c_char,
                name.len(),
                trampoline::<F>,
                boxed as *mut c_void,
                arity as c_int,
                constructable as c_int,
            )
        };

        if status != sys::JSE_OK {
            // Registration failed, so the engine never took the pointer and we
            // still own it uniquely. Reclaim it rather than leaking on a path
            // that has no runtime-lifetime justification.
            // SAFETY: `boxed` came from `Box::into_raw` above and, since
            // registration failed, no copy of it escaped.
            drop(unsafe { Box::from_raw(boxed) });
            return Err(self.error(status));
        }
        Ok(())
        // `boxed` is intentionally not freed on the success path.
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
        read_string(self.rt.raw, self.handle, Some(self.rt))
    }

    /// Render a primitive the way JS would display it.
    ///
    /// The ABI has no coercion entry point, so this covers only the primitives
    /// that can be read directly. For objects, arrays, and functions, call
    /// `String(x)` or `JSON.stringify(x)` inside the snippet you evaluate.
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

// =========================================================================
// Host functions
// =========================================================================

/// A value seen inside a host callback.
///
/// The `'a` lifetime is that of the call itself. Argument and `this` handles
/// are *scope* handles the engine invalidates the moment the callback returns,
/// so `'a` is what stops one being stashed in a `static` or returned past the
/// closure — the mistake the C ABI can only warn about in prose.
///
/// A `HostValue` does not free anything on drop. Scope handles have nothing to
/// free; a [`Ctx::call`] result is owned by its [`Retained`] guard, which frees
/// the slot when it drops, or by the call itself after [`Retained::keep`].
#[derive(Clone, Copy)]
pub struct HostValue<'a> {
    repr: Repr,
    /// Invariant in `'a`: `HostValue<'long>` must not coerce to
    /// `HostValue<'short>` or vice versa, so no lifetime laundering can smuggle
    /// a handle out of the call it belongs to.
    _call: PhantomData<*mut &'a ()>,
}

/// What a [`HostValue`] stands for.
///
/// The ABI has no "construct a value" entry point — only the `jse_return_*`
/// setters, which are last-write-wins on the pending return value. So a value
/// the host *builds* cannot be a handle yet. It is held as data and applied
/// only if it is the one actually returned, which is what makes building
/// several and returning any one of them behave as written.
#[derive(Clone, Copy)]
enum Repr {
    /// An engine handle: an argument, `this`, or a [`Ctx::call`] result.
    Handle(sys::jse_value),
    /// A value built by the host, parked in the call's arena at this index.
    Built(usize),
}

impl<'a> HostValue<'a> {
    fn handle(handle: sys::jse_value) -> Self {
        HostValue {
            repr: Repr::Handle(handle),
            _call: PhantomData,
        }
    }

    fn built(index: usize) -> Self {
        HostValue {
            repr: Repr::Built(index),
            _call: PhantomData,
        }
    }

    /// The engine handle behind this value, if it has one. Values the host
    /// built have no handle until they are returned.
    fn raw(&self) -> Option<sys::jse_value> {
        match self.repr {
            Repr::Handle(h) => Some(h),
            Repr::Built(_) => None,
        }
    }
}

/// Reading a host-built value back is not supported: the engine has not made it
/// yet, so there is nothing to read. Every reader reports this rather than
/// guessing.
const NOT_READABLE: &str = "a host-built value cannot be read back; it exists only to be returned";

impl<'a> HostValue<'a> {
    /// The value's JavaScript type.
    ///
    /// A value the host built reports [`Type::Undefined`], since the engine has
    /// not constructed it yet.
    pub fn type_of(&self) -> Type {
        match self.raw() {
            // SAFETY: inside a callback the readers accept a null runtime and
            // resolve scope handles through the active call context.
            Some(h) => Type::from_raw(unsafe { sys::jse_type_of(std::ptr::null_mut(), h) }),
            None => Type::Undefined,
        }
    }

    /// Read a number. Does not coerce: a non-number is [`Kind::Type`].
    pub fn as_number(&self) -> Result<f64, Error> {
        let handle = self.raw().ok_or_else(|| Error::new(Kind::Type, NOT_READABLE))?;
        let mut out = 0.0f64;
        // SAFETY: as `type_of`; `out` is a valid out-parameter.
        let status = unsafe { sys::jse_get_number(std::ptr::null_mut(), handle, &mut out) };
        if status != sys::JSE_OK {
            return Err(Error::new(Kind::from_status(status), "value is not a number"));
        }
        Ok(out)
    }

    /// Read a boolean. Does not coerce: a non-boolean is [`Kind::Type`].
    pub fn as_bool(&self) -> Result<bool, Error> {
        let handle = self.raw().ok_or_else(|| Error::new(Kind::Type, NOT_READABLE))?;
        let mut out: c_int = 0;
        // SAFETY: as `type_of`; `out` is a valid out-parameter.
        let status = unsafe { sys::jse_get_bool(std::ptr::null_mut(), handle, &mut out) };
        if status != sys::JSE_OK {
            return Err(Error::new(Kind::from_status(status), "value is not a boolean"));
        }
        Ok(out != 0)
    }

    /// Copy a string out as a Rust `String`. Does not coerce.
    pub fn as_string(&self) -> Result<String, Error> {
        let handle = self.raw().ok_or_else(|| Error::new(Kind::Type, NOT_READABLE))?;
        read_string(std::ptr::null_mut(), handle, None)
    }
}

impl fmt::Debug for HostValue<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self.repr {
            Repr::Handle(_) => write!(f, "HostValue({:?})", self.type_of()),
            Repr::Built(_) => f.write_str("HostValue(host-built)"),
        }
    }
}

/// The context of one host-function call.
///
/// Handed to the closure by reference and never outlives the call. Everything
/// reachable from it borrows `'a`, so the borrow checker rejects a value
/// escaping into a longer-lived place.
pub struct Ctx<'a> {
    raw: sys::jse_call_ctx,
    /// The runtime this call belongs to. [`jse_value_free`] needs it, and it is
    /// not reachable from a call context, so it rides in from the registration.
    rt: sys::jse_runtime,
    /// Values the host built, parked until one of them is returned. See
    /// [`Repr::Built`].
    built: std::cell::RefCell<Vec<Built>>,
    /// Slots handed to the call by [`Retained::keep`], freed when it returns.
    /// A [`Ctx::call`] result that is dropped normally never lands here.
    kept: std::cell::RefCell<Vec<sys::jse_value>>,
    /// Invariant in `'a`, for the same reason as [`HostValue`].
    _call: PhantomData<*mut &'a ()>,
}

impl<'a> Ctx<'a> {
    fn new(raw: sys::jse_call_ctx, rt: sys::jse_runtime) -> Self {
        Ctx {
            raw,
            rt,
            built: std::cell::RefCell::new(Vec::new()),
            kept: std::cell::RefCell::new(Vec::new()),
            _call: PhantomData,
        }
    }

    /// Park a host-built value and hand back a `HostValue` naming it.
    fn park(&self, value: Built) -> HostValue<'a> {
        let mut built = self.built.borrow_mut();
        built.push(value);
        HostValue::built(built.len() - 1)
    }

    /// How many arguments JS passed. Unrelated to the registered arity.
    pub fn argc(&self) -> u32 {
        // SAFETY: `self.raw` is the live context for this call.
        unsafe { sys::jse_argc(self.raw) }
    }

    /// Argument `i`, or `undefined` at or past [`Ctx::argc`] — matching JS,
    /// where reading a missing argument is not an error.
    pub fn arg(&self, i: u32) -> HostValue<'a> {
        // SAFETY: the ABI documents out-of-range indices as yielding undefined.
        HostValue::handle(unsafe { sys::jse_arg(self.raw, i) })
    }

    /// The `this` receiver. Strict semantics: an undefined receiver stays
    /// undefined rather than becoming the global object.
    pub fn this(&self) -> HostValue<'a> {
        // SAFETY: live context.
        HostValue::handle(unsafe { sys::jse_this(self.raw) })
    }

    /// `new.target`, or `undefined` on a plain call.
    pub fn new_target(&self) -> HostValue<'a> {
        // SAFETY: live context.
        HostValue::handle(unsafe { sys::jse_new_target(self.raw) })
    }

    /// Whether this invocation came through `new` or `super()`.
    pub fn is_construct(&self) -> bool {
        // SAFETY: live context.
        unsafe { sys::jse_is_construct(self.raw) != 0 }
    }

    /// A number to return from the closure.
    pub fn number(&self, n: f64) -> HostValue<'a> {
        self.park(Built::Number(n))
    }

    /// A boolean to return from the closure.
    pub fn bool(&self, b: bool) -> HostValue<'a> {
        self.park(Built::Bool(b))
    }

    /// A string to return from the closure. Copied into the engine when
    /// returned.
    pub fn string(&self, s: &str) -> HostValue<'a> {
        self.park(Built::Str(s.to_string()))
    }

    /// JS `null`.
    pub fn null(&self) -> HostValue<'a> {
        self.park(Built::Null)
    }

    /// JS `undefined`. This is what a closure returns when it has no result.
    pub fn undefined(&self) -> HostValue<'a> {
        self.park(Built::Undefined)
    }

    /// Call a JS function from inside this callback.
    ///
    /// `this_val` may be `None` for an undefined receiver. If the callee
    /// throws, the exception is recorded on this call and returned as
    /// [`Kind::Throw`]; propagate it by returning `Err` promptly rather than
    /// evaluating anything else. Calling a non-function is a `TypeError`, and
    /// a host → JS → host chain that nests too deeply gets a `RangeError`
    /// instead of blowing the native stack.
    ///
    /// Host-built values ([`Ctx::number`] and friends) cannot be passed here:
    /// the ABI has no way to construct one except as a return value, so they
    /// have no handle to hand over. Arguments, `this`, and earlier `call`
    /// results all work.
    ///
    /// The result is a [`Retained`] guard that releases its registry slot on
    /// drop. The registry is finite, so a loop that calls JS must not
    /// hold every result at once — dropping each one as the loop turns is what
    /// keeps an unbounded number of calls inside a single callback working.
    /// Deref to use it as a [`HostValue`], or [`Retained::keep`] to hold it for
    /// the rest of the call.
    pub fn call(
        &self,
        func: HostValue<'a>,
        args: &[HostValue<'a>],
        this_val: Option<HostValue<'a>>,
    ) -> Result<Retained<'a, '_>, Error> {
        let not_passable = || Error::new(Kind::Type, "a host-built value cannot be passed to call");

        let func_handle = func.raw().ok_or_else(not_passable)?;
        let raw_args: Vec<sys::jse_value> = args
            .iter()
            .map(|v| v.raw().ok_or_else(not_passable))
            .collect::<Result<_, _>>()?;
        let this_handle = match this_val {
            Some(v) => v.raw().ok_or_else(not_passable)?,
            None => sys::JSE_INVALID_VALUE,
        };
        let mut out: sys::jse_value = sys::JSE_INVALID_VALUE;

        // SAFETY: live context; `raw_args` is valid for its length (a null
        // pointer when empty is what the ABI wants for "no arguments");
        // `out` is a valid out-parameter.
        let status = unsafe {
            sys::jse_call(
                self.raw,
                func_handle,
                if raw_args.is_empty() {
                    std::ptr::null()
                } else {
                    raw_args.as_ptr()
                },
                raw_args.len() as u32,
                this_handle,
                &mut out,
            )
        };

        // Only JSE_ERR_THROW means the callee raised a JS exception, and only
        // then has the engine staged it on this context. JSE_ERR_FULL and
        // JSE_ERR_INVALID come back with nothing staged, so tagging them as an
        // already-recorded throw would make the trampoline suppress a message
        // that was never recorded -- the failure would vanish.
        if status == sys::JSE_ERR_THROW {
            return Err(Error::new(Kind::Throw, CALLEE_THREW));
        }
        if status != sys::JSE_OK {
            let kind = Kind::from_status(status);
            return Err(Error::new(kind, match kind {
                Kind::Full => "the value registry is full; release earlier call \
                               results before making more calls",
                Kind::Invalid => "jse_call rejected its arguments",
                _ => kind.describe(),
            }));
        }

        // The result is a runtime-owned registry slot. The guard frees it on
        // drop rather than letting it accumulate until the call returns.
        Ok(Retained {
            value: HostValue::handle(out),
            ctx: self,
        })
    }

    /// Free a runtime-owned handle produced by [`Ctx::call`].
    fn release(&self, handle: sys::jse_value) {
        // SAFETY: `handle` came from a successful `jse_call` on this context,
        // so it names a runtime-owned slot in `self.rt`. `Retained` frees it
        // exactly once, on drop.
        unsafe { sys::jse_value_free(self.rt, handle) };
    }
}

/// A [`Ctx::call`] result, holding one of the runtime's registry slots.
///
/// Dropping it frees the slot. That is what lets a host callback call JS an
/// unbounded number of times: without it, every result would be held until the
/// callback returned and the 1025th call would fail with [`Kind::Full`].
///
/// Deref gives the underlying [`HostValue`], so a result reads and passes on
/// like any other value:
///
/// ```ignore
/// let r = ctx.call(f, &[], None)?;
/// let n = r.as_number()?;      // read through the deref
/// let s = ctx.call(g, &[*r], None)?;  // pass it along while `r` is alive
/// ```
///
/// To keep a result past the statement that made it, either bind it to a
/// variable — it lives as long as the binding — or call [`Retained::keep`] to
/// hand ownership to the call, which frees it when the callback returns.
pub struct Retained<'a, 'c> {
    value: HostValue<'a>,
    ctx: &'c Ctx<'a>,
}

impl<'a> Retained<'a, '_> {
    /// Give up the guard and let the enclosing host call free the slot when it
    /// returns.
    ///
    /// Use this for the value a closure is about to return, or for a handful of
    /// results that must outlive their statements. It costs one of the
    /// slots until the callback ends, so it does not belong in a loop.
    pub fn keep(self) -> HostValue<'a> {
        let value = self.value;
        if let Some(h) = value.raw() {
            self.ctx.kept.borrow_mut().push(h);
        }
        // The slot is the call's responsibility now, so skip the drop that
        // would otherwise free it here.
        std::mem::forget(self);
        value
    }
}

impl<'a> std::ops::Deref for Retained<'a, '_> {
    type Target = HostValue<'a>;

    fn deref(&self) -> &HostValue<'a> {
        &self.value
    }
}

impl Drop for Retained<'_, '_> {
    fn drop(&mut self) {
        if let Some(h) = self.value.raw() {
            self.ctx.release(h);
        }
    }
}

impl fmt::Debug for Retained<'_, '_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "Retained({:?})", self.value)
    }
}

/// Marker message for a failure that the engine has *already* recorded as a
/// throw. The trampoline must not overwrite it with a second throw, which would
/// replace the callee's real exception with a generic one.
const CALLEE_THREW: &str = "\u{0}jse: exception already recorded";

/// A value the host built, held as data until it is returned.
///
/// The `jse_return_*` setters are last-write-wins on a single pending return
/// value, so applying one eagerly would make the *last* value a closure built
/// win over whichever it actually returned. Holding the data instead and
/// applying it once, in the trampoline, is what makes
/// `let a = ctx.number(1); let _ = ctx.number(2); Ok(a)` yield 1.
enum Built {
    Number(f64),
    Bool(bool),
    Str(String),
    Null,
    Undefined,
}

impl Built {
    /// Set this as the call's return value. Called at most once per call.
    fn apply(&self, raw: sys::jse_call_ctx) {
        match self {
            // SAFETY: live context in every arm; the string pointer is valid
            // for its length across the call, which copies it into the engine.
            Built::Number(n) => unsafe { sys::jse_return_number(raw, *n) },
            Built::Bool(b) => unsafe { sys::jse_return_bool(raw, *b as c_int) },
            Built::Null => unsafe { sys::jse_return_null(raw) },
            // A callback that sets no return value already yields undefined.
            Built::Undefined => {}
            Built::Str(s) => unsafe {
                sys::jse_return_string(raw, s.as_ptr() as *const c_char, s.len())
            },
        }
    }
}

/// Read a string through the ABI's measure-then-fill protocol.
///
/// Shared by [`Value::as_string`] and [`HostValue::as_string`]. Inside a
/// callback `rt` is null — the readers resolve scope handles through the active
/// call context — and `owner` is `None`, so failures carry a generic message
/// instead of the engine's, which needs a runtime to read.
fn read_string(
    rt: sys::jse_runtime,
    handle: sys::jse_value,
    owner: Option<&Runtime>,
) -> Result<String, Error> {
    let fail = |status: c_int| match owner {
        Some(rt) => rt.error(status),
        None => Error::new(Kind::from_status(status), "value is not a string"),
    };

    let mut len: usize = 0;
    // Measure. A null buffer asks for the byte length, excluding the NUL.
    // SAFETY: `handle` is live; a null buf with cap 0 is the ABI's documented
    // measuring call; `len` is a valid out-parameter.
    let status = unsafe { sys::jse_get_string(rt, handle, std::ptr::null_mut(), 0, &mut len) };
    if status != sys::JSE_OK {
        return Err(fail(status));
    }

    // Fill. The ABI writes a trailing NUL, so ask for len + 1.
    let mut buf = vec![0u8; len + 1];
    // SAFETY: `buf` has exactly the capacity the ABI requires, and the call
    // writes at most that many bytes.
    let status = unsafe {
        sys::jse_get_string(rt, handle, buf.as_mut_ptr() as *mut c_char, buf.len(), &mut len)
    };
    if status != sys::JSE_OK {
        return Err(fail(status));
    }

    buf.truncate(len);
    String::from_utf8(buf)
        .map_err(|_| Error::new(Kind::Encoding, "engine returned a non-UTF-8 string"))
}

/// What a registration leaks: the host closure plus the runtime it belongs to.
///
/// The runtime pointer is not reachable from a call context, and the trampoline
/// needs it to free the runtime-owned handles [`Ctx::call`] produces.
struct Registration<F> {
    rt: sys::jse_runtime,
    f: F,
}

/// The one `extern "C"` function every registration goes through.
///
/// Monomorphised per closure type `F`, so recovering the closure from `udata`
/// is a plain cast rather than a vtable hop. Four things must hold on every
/// path out of here, and all four are why this is not just a call:
///
/// 1. **Nothing unwinds.** A Rust panic crossing into C is undefined behaviour,
///    so the closure runs inside [`catch_unwind`] and a caught panic becomes a
///    JS throw.
/// 2. **The engine keeps its own recorded throw.** [`Ctx::call`] failures are
///    already recorded engine-side; re-throwing over them would replace the
///    callee's real exception with a generic one.
/// 3. **The returned value is the one applied.** Host-built values are held as
///    data until here, because the `jse_return_*` setters are last-write-wins
///    and would otherwise let a discarded value win. See [`Built`].
/// 4. **Kept handles are released.** A [`Ctx::call`] result frees its slot when
///    its [`Retained`] guard drops, so most never reach here; the ones handed
///    over by [`Retained::keep`] are freed here, once, whatever the closure did.
///
/// # Safety
///
/// Called only by the engine, with the `udata` pointer this crate registered:
/// a live `*mut F` from `Box::into_raw` that is never freed while the runtime
/// lives.
unsafe extern "C" fn trampoline<F>(raw: sys::jse_call_ctx, udata: *mut c_void)
where
    F: for<'a> Fn(&Ctx<'a>) -> Result<HostValue<'a>, Error> + 'static,
{
    if raw.is_null() || udata.is_null() {
        return;
    }
    // SAFETY: `udata` is the leaked `*mut Registration<F>` from
    // `register_fn_impl`, alive for the runtime's lifetime. Taken as a shared
    // reference only; the closure is `Fn`, so re-entrant calls
    // (host -> JS -> same host) are fine.
    let reg: &Registration<F> = unsafe { &*(udata as *const Registration<F>) };

    let ctx = Ctx::new(raw, reg.rt);

    // AssertUnwindSafe: on a panic we touch `ctx` only to record a throw and
    // free handles, neither of which reads closure state that a panic could
    // have left inconsistent.
    let result = catch_unwind(AssertUnwindSafe(|| (reg.f)(&ctx)));

    match result {
        // Apply exactly the value the closure returned, ignoring any others it
        // built along the way.
        Ok(Ok(v)) => match v.repr {
            // SAFETY: live context; the handle came from this call.
            Repr::Handle(h) => unsafe { sys::jse_return(raw, h) },
            // The index came from `Ctx::park` on this same context, so it is
            // always in bounds.
            Repr::Built(i) => ctx.built.borrow()[i].apply(raw),
        },

        // The closure failed. Unless the engine already recorded the throw
        // itself (a `Ctx::call` that propagated a callee exception), convert
        // the error into one. A recorded throw beats any return value, so a
        // partially-built result is discarded automatically.
        Ok(Err(e)) => {
            if e.message() != CALLEE_THREW {
                throw_message(raw, e.throw_kind(), e.message());
            }
        }

        // The closure panicked. Nothing may unwind past here, so turn it into
        // a JS throw the script can catch, keeping the engine consistent.
        Err(payload) => {
            let msg = format!("host panic: {}", panic_message(&payload));
            throw_message(raw, sys::JSE_ERROR, &msg);
        }
    }

    // Release the slots `Retained::keep` handed to the call. Results dropped
    // normally are already gone, which is what lets a callback call JS more
    // than the registry ceiling. Scope handles are not in here; the engine reclaims
    // those when the call frame goes.
    for handle in ctx.kept.borrow().iter() {
        // SAFETY: each handle came from a successful `jse_call` on this
        // context, is runtime-owned, and is freed exactly once: `keep` forgets
        // the guard that would otherwise free it, and pushes it here once.
        unsafe { sys::jse_value_free(reg.rt, *handle) };
    }
}

/// Record a JS throw carrying `msg`, tolerating a message with interior NULs by
/// truncating at the first one — the ABI takes a NUL-terminated string.
fn throw_message(raw: sys::jse_call_ctx, kind: c_int, msg: &str) {
    let cstr = CString::new(msg).unwrap_or_else(|e| {
        let upto = e.nul_position();
        // Position of a NUL byte is a valid UTF-8 boundary, so this cannot
        // split a character.
        CString::new(&e.into_vec()[..upto]).expect("truncated at the first NUL")
    });
    // SAFETY: live context; `cstr` is NUL-terminated and outlives the call,
    // which copies the message.
    unsafe { sys::jse_throw_error(raw, kind, cstr.as_ptr()) };
}

/// Best-effort text for a panic payload. `panic!("x")` and
/// `panic!("{}", x)` produce `&str` and `String` respectively; anything else
/// carries no printable message.
fn panic_message(payload: &Box<dyn Any + Send>) -> &str {
    if let Some(s) = payload.downcast_ref::<&str>() {
        s
    } else if let Some(s) = payload.downcast_ref::<String>() {
        s
    } else {
        "unknown"
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
