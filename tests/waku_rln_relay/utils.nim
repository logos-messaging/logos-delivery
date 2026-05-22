import web3, chronos, stew/byteutils

proc deployContract*(
    web3: Web3, code: string, gasPrice = 0, contractInput = ""
): Future[ReceiptObject] {.async.} =
  # the contract input is the encoded version of contract constructor's input
  # use nim-web3/encoding.nim module to find the appropriate encoding procedure for different argument types
  # e.g., consider the following contract constructor in solidity
  # 	constructor(uint256 x, uint256 y)
  #
  # the contractInput can be calculated as follows
  # let
  #   x = 1.u256
  #   y = 5.u256
  # contractInput = encode(x).data  &  encode(y).data
  # Note that the order of encoded inputs should match the order of the constructor inputs
  let provider = web3.provider
  let accounts = await provider.eth_accounts()

  var code = code
  if code[1] notin {'x', 'X'}:
    code = "0x" & code
  var tr: TransactionArgs
  tr.`from` = Opt.some(web3.defaultAccount)
  let sData = code & contractInput
  tr.data = Opt.some(hexToSeqByte(sData))
  if gasPrice != 0:
    tr.gasPrice = Opt.some(gasPrice.Quantity)

  let r = await web3.send(tr)
  return await web3.getMinedTransactionReceipt(r)
