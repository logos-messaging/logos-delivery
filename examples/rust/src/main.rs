use std::os::raw::{c_char, c_int, c_void};
use std::sync::mpsc::{channel, Sender};
use std::{slice, thread, time};

use ciborium::value::Value;

// These declarations are hand-written rather than generated from
// build/generated/logosdelivery.h, so nothing checks them against it: a stale
// one compiles and links cleanly and only misbehaves at run time. Keep them in
// step with the header by hand.
//
// The raw entry points take their request as a CBOR map and answer with a
// CBOR value on success, or with the plain error text on failure.

const RET_OK: c_int = 0;
const RET_STALE_WARN: c_int = 3;

/// FFICallback: `msg` is a byte run of `len` bytes.
type RawFn = unsafe extern "C" fn(c_int, *const c_char, usize, *mut c_void);

extern "C" {
    fn logosdelivery_create_node(
        req_cbor: *const u8,
        req_cbor_len: usize,
        cb: RawFn,
        user_data: *mut c_void,
    ) -> *mut c_void;

    fn logosdelivery_start_node(
        ctx: *mut c_void,
        cb: RawFn,
        user_data: *mut c_void,
        req_cbor: *const u8,
        req_cbor_len: usize,
    ) -> c_int;

    fn waku_version(
        ctx: *mut c_void,
        cb: RawFn,
        user_data: *mut c_void,
        req_cbor: *const u8,
        req_cbor_len: usize,
    ) -> c_int;

    fn waku_default_pubsub_topic(
        ctx: *mut c_void,
        cb: RawFn,
        user_data: *mut c_void,
        req_cbor: *const u8,
        req_cbor_len: usize,
    ) -> c_int;
}

type Reply = Result<Value, String>;

/// The library answers on its own thread; `user_data` is a leaked sender that
/// the terminal reply takes back.
unsafe extern "C" fn on_reply(ret: c_int, msg: *const c_char, len: usize, user_data: *mut c_void) {
    if ret == RET_STALE_WARN {
        return;
    }
    let tx = Box::from_raw(user_data as *mut Sender<Reply>);
    let bytes = if msg.is_null() {
        &[][..]
    } else {
        slice::from_raw_parts(msg as *const u8, len)
    };
    let reply = if ret == RET_OK {
        ciborium::from_reader(bytes).map_err(|e| format!("could not decode reply: {e}"))
    } else {
        Err(String::from_utf8_lossy(bytes).into_owned())
    };
    let _ = tx.send(reply);
}

fn encode(fields: Vec<(&str, Value)>) -> Vec<u8> {
    let map = Value::Map(fields.into_iter().map(|(k, v)| (Value::Text(k.into()), v)).collect());
    let mut buf = Vec::new();
    ciborium::into_writer(&map, &mut buf).expect("CBOR encoding into a Vec cannot fail");
    buf
}

/// Runs one raw call and waits for its terminal reply.
fn call(what: &str, req: Vec<u8>, f: impl FnOnce(&[u8], *mut c_void) -> c_int) -> Value {
    let (tx, rx) = channel::<Reply>();
    let user_data = Box::into_raw(Box::new(tx)) as *mut c_void;
    let ret = f(&req, user_data);
    if ret != RET_OK {
        panic!("{what} was not accepted: {ret}");
    }
    match rx.recv_timeout(time::Duration::from_secs(30)) {
        Ok(Ok(value)) => value,
        Ok(Err(err)) => panic!("{what} failed: {err}"),
        Err(err) => panic!("no reply from {what}: {err}"),
    }
}

fn text(value: Value) -> String {
    value.into_text().unwrap_or_else(|v| format!("{v:?}"))
}

fn main() {
    let config_json = r#"{
        "mode": "Core",
        "messagingOverrides": {
            "listen-address": "127.0.0.1",
            "tcp-port": 60000,
            "nodekey": "0d714a1fada214dead6dc9c7274581ec20ff292451866e7d6d677dc818e8ccd2",
            "log-level": "DEBUG"
        }
    }"#;

    // The create reply carries the context address as decimal text.
    let addr = call(
        "logosdelivery_create_node",
        encode(vec![("configJson", Value::Text(config_json.into()))]),
        |req, ud| unsafe {
            logosdelivery_create_node(req.as_ptr(), req.len(), on_reply, ud);
            RET_OK
        },
    );
    let ctx = text(addr)
        .parse::<usize>()
        .expect("logosdelivery_create_node replied with a non-numeric address")
        as *mut c_void;

    let empty = || encode(vec![]);

    let version = call("waku_version", empty(), |req, ud| unsafe {
        waku_version(ctx, on_reply, ud, req.as_ptr(), req.len())
    });
    println!("Version: {}", text(version));

    let topic = call("waku_default_pubsub_topic", empty(), |req, ud| unsafe {
        waku_default_pubsub_topic(ctx, on_reply, ud, req.as_ptr(), req.len())
    });
    println!("Default pubsubTopic: {}", text(topic));

    call("logosdelivery_start_node", empty(), |req, ud| unsafe {
        logosdelivery_start_node(ctx, on_reply, ud, req.as_ptr(), req.len())
    });
    println!("Node started");

    loop {
        thread::sleep(time::Duration::from_millis(10000));
    }
}
