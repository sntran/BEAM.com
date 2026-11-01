use std::cell::Cell;
use std::collections::HashMap;
use std::sync::{Arc, Condvar, Mutex, OnceLock};
use std::thread;
use std::time::Instant;

thread_local! { static LOCAL: Cell<u64> = Cell::new(0); }
static ONCE: OnceLock<u64> = OnceLock::new();

/// A check of the parts of std that a NIF uses. Gives 0 when each part works.
#[no_mangle]
pub extern "C" fn rs_probe() -> i32 {
    let start = Instant::now();
    // Threads on one Mutex: the contention needs the futex.
    let counter = Arc::new(Mutex::new(0u64));
    let handles: Vec<_> = (0..8)
        .map(|_| {
            let c = Arc::clone(&counter);
            thread::spawn(move || {
                for _ in 0..100_000 {
                    *c.lock().unwrap() += 1;
                    LOCAL.with(|l| l.set(l.get() + 1));
                }
                LOCAL.with(|l| l.get())
            })
        })
        .collect();
    let locals: u64 = handles.into_iter().map(|h| h.join().unwrap()).sum();
    if *counter.lock().unwrap() != 800_000 || locals != 800_000 { return 1; }
    // Thread-locals stay per thread: the main thread has 0.
    if LOCAL.with(|l| l.get()) != 0 { return 2; }
    // A Condvar between two threads.
    let pair = Arc::new((Mutex::new(false), Condvar::new()));
    let p2 = Arc::clone(&pair);
    let t = thread::spawn(move || { *p2.0.lock().unwrap() = true; p2.1.notify_one(); });
    let mut ready = pair.0.lock().unwrap();
    while !*ready { ready = pair.1.wait(ready).unwrap(); }
    drop(ready);
    t.join().unwrap();
    // OnceLock from 4 threads at once.
    let hs: Vec<_> = (0..4).map(|i| thread::spawn(move || *ONCE.get_or_init(|| 40 + i as u64 * 0 + 2))).collect();
    if hs.into_iter().any(|h| h.join().unwrap() != 42) { return 3; }
    // HashMap: its RandomState reads random bytes.
    let mut m = HashMap::new();
    for i in 0..1000 { m.insert(i, i * 2); }
    if m[&500] != 1000 { return 4; }
    // A panic that unwinds and stops at catch_unwind.
    if std::panic::catch_unwind(|| { if m.len() > 0 { panic!("probe") } }).is_ok() { return 5; }
    if start.elapsed().as_secs() > 60 { return 6; }
    // The clocks: a sleep, and a wait with a timeout that ends.
    let t0 = Instant::now();
    thread::sleep(std::time::Duration::from_millis(50));
    if t0.elapsed() < std::time::Duration::from_millis(45) { return 7; }
    let (m, cv) = (Mutex::new(()), Condvar::new());
    let (_g, timeout) = cv.wait_timeout(m.lock().unwrap(), std::time::Duration::from_millis(30)).unwrap();
    if !timeout.timed_out() { return 8; }
    // The number of CPUs: rayon uses it.
    match thread::available_parallelism() { Ok(n) if n.get() >= 1 => {}, _ => return 9 }
    0
}
