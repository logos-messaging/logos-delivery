## Logos Delivery API layer: logos_delivery/{api,messaging,channels}
##
## Kept out of all_tests_waku because refc caps a binary at 3500 GC-traced
## globals (nimRegisterGlobalMarker), and the combined suite had reached it.

# Waku API tests
import ./api/test_all

# Messaging API tests
import ./messaging/test_all

# Reliable Channel API tests
import ./channels/test_all
