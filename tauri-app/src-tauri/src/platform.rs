use std::ffi::c_void;
use std::time::Duration;

#[cfg(target_os = "macos")]
extern "C" {
    // `dispatch_get_main_queue()` is a macro around this object. It is not a
    // linkable function, and a direct call fails under Tauri's linker flags.
    static _dispatch_main_q: u8;
    fn dispatch_async_f(queue: *const u8, context: *mut c_void, work: extern "C" fn(*mut c_void));
    fn pthread_main_np() -> i32;
}

#[cfg(target_os = "macos")]
extern "C" fn run_boxed(context: *mut c_void) {
    let work = unsafe { Box::from_raw(context as *mut Box<dyn FnOnce() + Send>) };
    work();
}

/// Queue `work` for the next main-queue turn.
///
/// The global-shortcut callback holds the shortcut lock on the main thread.
/// Registering another shortcut from inside that callback waits on the same
/// lock and macOS reports the app as not responding. A queued block runs
/// only after the callback has returned the lock.
pub fn defer_main(work: impl FnOnce() + Send + 'static) {
    #[cfg(target_os = "macos")]
    {
        let boxed: Box<dyn FnOnce() + Send> = Box::new(work);
        let context = Box::into_raw(Box::new(boxed)) as *mut c_void;
        unsafe {
            dispatch_async_f(std::ptr::addr_of!(_dispatch_main_q), context, run_boxed);
        }
    }
    #[cfg(not(target_os = "macos"))]
    {
        work();
    }
}

/// Run `work` on the main thread and wait for its result.
/// Inline when already on the main thread, so a nested wait cannot deadlock.
pub fn on_main_sync<R: Send + 'static>(
    work: impl FnOnce() -> R + Send + 'static,
) -> Result<R, String> {
    #[cfg(target_os = "macos")]
    {
        if unsafe { pthread_main_np() } != 0 {
            return Ok(work());
        }
        let (tx, rx) = std::sync::mpsc::sync_channel(1);
        defer_main(move || {
            let _ = tx.send(work());
        });
        return rx.recv_timeout(Duration::from_secs(4)).map_err(|_| {
            "The main thread did not finish text insertion.".to_string()
        });
    }
    #[cfg(not(target_os = "macos"))]
    {
        Ok(work())
    }
}
