use std::cell::OnceCell;
use std::ffi::CString;
use std::os::raw::{c_char, c_int, c_void};
use std::{slice, thread, time};

// These declarations are hand-written rather than generated from
// library/generated/logosdelivery.h, so nothing checks them against it: a stale
// one compiles and links cleanly and only misbehaves at run time. Keep them in
// step with the header by hand.

/// LogosDeliveryScalarRawFn: `msg` is a byte run of `len` bytes.
pub type ScalarRawFn = unsafe extern "C" fn(c_int, *mut c_char, usize, *const c_void);

/// LogosDeliveryCreateRawFn: carries the context address, and the failure text
/// in its own argument rather than in the payload.
pub type CreateRawFn =
    unsafe extern "C" fn(c_int, *const c_char, *const c_char, *const c_void);

#[repr(C)]
pub struct LogosdeliveryCreateNodeCtorReq {
    pub config_json: *const c_char,
}

extern "C" {
    pub fn logosdelivery_create_node(
        req: *const LogosdeliveryCreateNodeCtorReq,
        on_created: CreateRawFn,
        user_data: *const c_void,
    ) -> *mut c_void;

    pub fn waku_version(ctx: *const c_void, cb: ScalarRawFn, user_data: *const c_void) -> c_int;

    pub fn logosdelivery_start_node(
        ctx: *const c_void,
        cb: ScalarRawFn,
        user_data: *const c_void,
    ) -> c_int;

    pub fn waku_default_pubsub_topic(
        ctx: *mut c_void,
        cb: ScalarRawFn,
        user_data: *const c_void,
    ) -> c_int;
}

pub unsafe extern "C" fn trampoline<C>(
    return_val: c_int,
    buffer: *mut c_char,
    buffer_len: usize,
    data: *const c_void,
) where
    C: FnMut(i32, &str),
{
    let closure = &mut *(data as *mut C);

    let buffer_utf8 =
        String::from_utf8(slice::from_raw_parts(buffer as *mut u8, buffer_len).to_vec())
            .expect("valid utf8");

    closure(return_val, &buffer_utf8);
}

pub fn get_trampoline<C>(_closure: &C) -> ScalarRawFn
where
    C: FnMut(i32, &str),
{
    trampoline::<C>
}

/// The create/reply shape has no length, so the payload is read as a C string.
pub unsafe extern "C" fn create_trampoline<C>(
    return_val: c_int,
    reply: *const c_char,
    err_msg: *const c_char,
    data: *const c_void,
) where
    C: FnMut(i32, &str),
{
    let closure = &mut *(data as *mut C);
    let text = if !reply.is_null() { reply } else { err_msg };
    let owned = if text.is_null() {
        String::new()
    } else {
        std::ffi::CStr::from_ptr(text).to_string_lossy().into_owned()
    };
    closure(return_val, &owned);
}

pub fn get_create_trampoline<C>(_closure: &C) -> CreateRawFn
where
    C: FnMut(i32, &str),
{
    create_trampoline::<C>
}

fn main() {
    let config_json = "\
    { \
        \"mode\": \"Core\",\
        \"messagingOverrides\": { \
            \"listen-address\": \"127.0.0.1\",\
            \"tcp-port\": 60000, \
            \"nodekey\": \"0d714a1fada214dead6dc9c7274581ec20ff292451866e7d6d677dc818e8ccd2\", \
            \"log-level\": \"DEBUG\"
        }
    }";

    unsafe {
        // Create the waku node
        let closure = |ret: i32, data: &str| {
            println!("Ret {ret}. logosdelivery_create_node closure called {data}");
        };
        let cb = get_create_trampoline(&closure);
        let config_json_str = CString::new(config_json).unwrap();
        let req = LogosdeliveryCreateNodeCtorReq {
            config_json: config_json_str.as_ptr(),
        };
        let ctx = logosdelivery_create_node(&req, cb, &closure as *const _ as *const c_void);

        // Extracting the current waku version
        let version: OnceCell<String> = OnceCell::new();
        let closure = |ret: i32, data: &str| {
            println!("version_closure. Ret: {ret}. Data: {data}");
            let _ = version.set(data.to_string());
        };
        let cb = get_trampoline(&closure);
        // `ctx` is already the context pointer; taking its address passed a
        // pointer to the local instead, which the library rejected.
        let _ret = waku_version(ctx, cb, &closure as *const _ as *const c_void);

        // Extracting the default pubsub topic
        let default_pubsub_topic: OnceCell<String> = OnceCell::new();
        let closure = |_ret: i32, data: &str| {
            let _ = default_pubsub_topic.set(data.to_string());
        };
        let cb = get_trampoline(&closure);
        let _ret = waku_default_pubsub_topic(ctx, cb, &closure as *const _ as *const c_void);

        println!("Version: {}", version.get_or_init(|| unreachable!()));
        println!(
            "Default pubsubTopic: {}",
            default_pubsub_topic.get_or_init(|| unreachable!())
        );

        // Start the Waku node
        let closure = |ret: i32, data: &str| {
            println!("Ret {ret}. logosdelivery_start_node closure called {data}");
        };
        let cb = get_trampoline(&closure);
        let _ret = logosdelivery_start_node(ctx, cb, &closure as *const _ as *const c_void);
    }

    loop {
        thread::sleep(time::Duration::from_millis(10000));
    }
}
