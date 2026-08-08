// ============================================================
// Synchronous call helper
// ============================================================
// Guarded so two nim-ffi headers can share a translation unit.
#ifndef NIM_FFI_SYNC_CALL_HELPER_HPP_INCLUDED
#define NIM_FFI_SYNC_CALL_HELPER_HPP_INCLUDED

namespace {

struct FFICallState_ {
    std::mutex              mtx;
    std::condition_variable cv;
    bool                    done{false};
    bool                    ok{false};
    std::vector<std::uint8_t> bytes;
    std::string             err;
};

inline void ffi_cb_(int ret, const char* msg, size_t len, void* ud) {
    // NIMFFI_RET_STALE_WARN (3) is a non-terminal progress ping: the request is
    // still running. This blocking wrapper only reports the final result, so
    // ignore it WITHOUT touching `ud` — a terminal callback still owns the
    // shared handle and will free it.
    if (ret == NIMFFI_RET_STALE_WARN) return;

    // ffi_call_ heap-allocated a shared_ptr and passed its address as ud;
    // take ownership here so it's freed on every exit path.
    std::unique_ptr<std::shared_ptr<FFICallState_>> handle(
        static_cast<std::shared_ptr<FFICallState_>*>(ud));
    FFICallState_& s = **handle;

    std::lock_guard<std::mutex> lock(s.mtx);
    s.ok = (ret == NIMFFI_RET_OK);
    if (msg && len > 0) {
        const auto* p = reinterpret_cast<const std::uint8_t*>(msg);
        if (s.ok) s.bytes.assign(p, p + len);
        else      s.err.assign(msg, len);
    }
    s.done = true;
    s.cv.notify_one();
}

inline Result<std::vector<std::uint8_t>> ffi_call_(
        std::function<int(FFICallback, void*)> f,
        std::chrono::milliseconds timeout) {
    using Bytes = std::vector<std::uint8_t>;
    auto state = std::make_shared<FFICallState_>();
    auto* cb_ref = new std::shared_ptr<FFICallState_>(state);
    const int ret = f(ffi_cb_, cb_ref);
    if (ret == NIMFFI_RET_MISSING_CALLBACK) {
        delete cb_ref;
        return Result<Bytes>::err("RET_MISSING_CALLBACK (internal error)");
    }
    std::unique_lock<std::mutex> lock(state->mtx);
    const bool fired = state->cv.wait_for(lock, timeout, [&]{ return state->done; });
    if (!fired)
        return Result<Bytes>::err("FFI call timed out after " +
                                  std::to_string(timeout.count()) + "ms");
    if (!state->ok)
        return Result<Bytes>::err(state->err);
    return Result<Bytes>::ok(std::move(state->bytes));
}

} // anonymous namespace

#endif // NIM_FFI_SYNC_CALL_HELPER_HPP_INCLUDED
