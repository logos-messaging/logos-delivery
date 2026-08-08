    // Special-member policy: this class owns a {{LIB}} context, which in
    // turn owns the library's worker thread(s) and internal state. Moving
    // such an object out from under a caller silently tears that state
    // down and is easy to misuse (e.g. storing in a container that
    // relocates its elements). It also has no clean analogue in the other
    // binding languages we generate. So copies and moves are both
    // deleted; ownership is transferred via {{CTX}}::create returning a
    // std::unique_ptr<{{CTX}}>. The destructor still releases the
    // context.
    ~{{CTX}}() {
        if (ptr_) {
            {{LIB}}_destroy(ptr_);
            ptr_ = nullptr;
        }
    }

    {{CTX}}(const {{CTX}}&) = delete;
    {{CTX}}& operator=(const {{CTX}}&) = delete;
    {{CTX}}({{CTX}}&&) = delete;
    {{CTX}}& operator=({{CTX}}&&) = delete;
