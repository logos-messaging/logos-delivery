import tools/confutils/cli_args
export cli_args

type KernelConf* = distinct WakuNodeConf
  ## Raw kernel config, for the kernel-only `new(KernelConf)` and the full-stack
  ## `new(KernelConf, ...)`.
