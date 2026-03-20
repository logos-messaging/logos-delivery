use std::cell::OnceCell;
use std::ffi::CString;
use std::os::raw::{c_char, c_int, c_void};
use std::{slice, thread, time};

pub type FFICallBack = unsafe extern "C" fn(c_int, *const c_char, usize, *const c_void);

extern "C" {
    pub fn waku_new(
        config_json: *const u8,
        cb: FFICallBack,
        user_data: *const c_void,
    ) -> *mut c_void;

    pub fn waku_version(ctx: *const c_void, cb: FFICallBack, user_data: *const c_void) -> c_int;

    pub fn waku_start(ctx: *const c_void, cb: FFICallBack, user_data: *const c_void) -> c_int;

    pub fn waku_default_pubsub_topic(
        ctx: *mut c_void,
        cb: FFICallBack,
        user_data: *const c_void,
    ) -> *mut c_void;
}

pub unsafe extern "C" fn trampoline<C>(
    return_val: c_int,
    buffer: *const c_char,
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

pub fn get_trampoline<C>(_closure: &C) -> FFICallBack
where
    C: FnMut(i32, &str),
{
    trampoline::<C>
}

fn main() {
    let config_json = "\
    { \
        \"host\": \"127.0.0.1\",\
        \"port\": 60000, \
        \"key\": \"0d714a1fada214dead6dc9c7274581ec20ff292451866e7d6d677dc818e8ccd2\", \
        \"relay\": true ,\
        \"logLevel\": \"DEBUG\"
    }";

    unsafe {
        // Create the waku node
        let closure = |ret: i32, data: &str| {
            println!("Ret {ret}. waku_new closure called {data}");
        };
        let cb = get_trampoline(&closure);
        let config_json_str = CString::new(config_json).unwrap();
        let ctx = waku_new(
            config_json_str.as_ptr() as *const u8,
            cb,
            &closure as *const _ as *const c_void,
        );

        // Extracting the current waku version
        let version: OnceCell<String> = OnceCell::new();
        let closure = |ret: i32, data: &str| {
            println!("version_closure. Ret: {ret}. Data: {data}");
            let _ = version.set(data.to_string());
        };
        let cb = get_trampoline(&closure);
        let _ret = waku_version(
            &ctx as *const _ as *const c_void,
            cb,
            &closure as *const _ as *const c_void,
        );

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
            println!("Ret {ret}. waku_start closure called {data}");
        };
        let cb = get_trampoline(&closure);
        let _ret = waku_start(ctx, cb, &closure as *const _ as *const c_void);
    }

    loop {
        thread::sleep(time::Duration::from_millis(10000));
    }
}
