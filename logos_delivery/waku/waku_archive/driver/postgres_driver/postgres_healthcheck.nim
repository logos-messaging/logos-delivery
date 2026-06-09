{.push raises: [].}

import chronos, results
import ../../../common/databases/db_postgres, ../../../common/error_handling

## Simple query to validate that the postgres is working and attending requests
const HealthCheckQuery = "SELECT version();"
const CheckConnectivityInterval = 60.seconds
const MaxNumTrials = 20
const TrialInterval = 1.seconds

proc checkConnectivity*(
    connPool: PgAsyncPool, onFatalErrorAction: OnFatalErrorHandler
) {.async.} =
  while true:
    (await connPool.pgQuery(HealthCheckQuery)).isOkOr:
      ## The connection failed once. Let's try reconnecting for a while.
      ## Notice that the 'exec' proc tries to establish a new connection.

      block errorBlock:
        ## Force close all the opened connections. No need to close gracefully.
        (await connPool.resetConnPool()).isOkOr:
          onFatalErrorAction("checkConnectivity resetConnPool error: " & error)

        var numTrial = 0
        while numTrial < MaxNumTrials:
          (await connPool.pgQuery(HealthCheckQuery)).isErrOr:
            ## Connection resumed. Let's go back to the normal healthcheck.
            break errorBlock

          await sleepAsync(TrialInterval)
          numTrial.inc()

        ## The connection couldn't be resumed. Let's inform the upper layers.
        onFatalErrorAction("postgres health check error: " & error)

    await sleepAsync(CheckConnectivityInterval)
