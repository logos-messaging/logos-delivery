import tools/confutils/kernel_cli_args
export kernel_cli_args

type KernelConf* = distinct WakuNodeConf
  ## Configuration of the kernel layer. `WakuNodeConf` is the legacy name for
  ## this configuration and stays while wakunode2 exists; when wakunode2 is
  ## deleted, `WakuNodeConf` is renamed `KernelConf` and this alias dies.
