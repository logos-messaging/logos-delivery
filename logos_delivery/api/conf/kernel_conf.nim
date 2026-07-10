import tools/confutils/cli_args
export cli_args

type KernelConf* = distinct WakuNodeConf
  ## Raw kernel config; distinct so `new(KernelConf)` doesn't collide with the
  ## full-stack `new(WakuNodeConf)`.
