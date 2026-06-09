type OnFatalErrorHandler* = proc(errMsg: string) {.gcsafe, closure, raises: [].}
