package com.mobile

import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod
import com.facebook.react.bridge.ReadableArray
import com.facebook.react.bridge.ReadableMap
import com.facebook.react.bridge.ReadableType
import com.facebook.react.bridge.WritableNativeArray
import com.facebook.react.modules.core.DeviceEventManagerModule
import com.google.gson.Gson
import java.math.BigInteger

class EventCallbackManager {
  companion object {

    lateinit var reactContext: ReactContext

    @JvmStatic
    fun execEventCallback(logosDeliveryPtr: Long, evt: String) {
      val params =
          Arguments.createMap().apply {
            putString("logosDeliveryPtr", logosDeliveryPtr.toString())
            putString("event", evt)
          }

      reactContext
          .getJSModule(DeviceEventManagerModule.RCTDeviceEventEmitter::class.java)
          .emit("logosDeliveryEvent", params)
    }
  }
}

// The library answers a comma-separated list.
fun convertStringToArray(stringArray: String): WritableNativeArray {
  val writableArray = WritableNativeArray()
  stringArray.split(",").filter { it.isNotEmpty() }.forEach { writableArray.pushString(it) }
  return writableArray
}

fun stringifyReadableMap(map: ReadableMap): String {
  val gson = Gson()
  return gson.toJson(readableMapToMap(map))
}

fun readableMapToMap(readableMap: ReadableMap): Map<String, Any?> {
  val map = mutableMapOf<String, Any?>()
  val iterator = readableMap.keySetIterator()
  while (iterator.hasNextKey()) {
    val key = iterator.nextKey()
    when (readableMap.getType(key)) {
      ReadableType.Null -> map[key] = null
      ReadableType.Boolean -> map[key] = readableMap.getBoolean(key)
      ReadableType.Number -> map[key] = readableMap.getInt(key)
      ReadableType.String -> map[key] = readableMap.getString(key)
      ReadableType.Map -> map[key] = readableMapToMap(readableMap.getMap(key)!!)
      ReadableType.Array -> map[key] = readableArrayToList(readableMap.getArray(key)!!)
    }
  }
  return map
}

fun readableArrayToList(readableArray: ReadableArray): List<Any?> {
  val list = mutableListOf<Any?>()
  for (i in 0 until readableArray.size()) {
    when (readableArray.getType(i)) {
      ReadableType.Null -> list.add(null)
      ReadableType.Boolean -> list.add(readableArray.getBoolean(i))
      ReadableType.Number -> list.add(readableArray.getInt(i))
      ReadableType.String -> list.add(readableArray.getString(i))
      ReadableType.Map -> list.add(readableMapToMap(readableArray.getMap(i)))
      ReadableType.Array -> list.add(readableArrayToList(readableArray.getArray(i)))
    }
  }
  return list
}

class LogosDeliveryPtr(val error: Boolean, val errorMessage: String, val ptr: Long)

class LogosDeliveryResult(val error: Boolean, val message: String)

class LogosDeliveryModule(reactContext: ReactApplicationContext) : ReactContextBaseJavaModule(reactContext) {
  var reactContext = reactContext

  override fun getName() = "LogosDeliveryModule"

  external fun logosDeliverySetup()
  external fun logosDeliveryNew(configJson: String): LogosDeliveryPtr
  external fun logosDeliveryStart(ctx: Long): LogosDeliveryResult
  external fun logosDeliveryVersion(ctx: Long): LogosDeliveryResult
  external fun logosDeliveryStop(ctx: Long): LogosDeliveryResult
  external fun logosDeliveryDestroy(ctx: Long): LogosDeliveryResult
  external fun logosDeliveryConnect(ctx: Long, peerMultiAddr: String, timeoutMs: Int): LogosDeliveryResult
  external fun logosDeliveryListenAddresses(ctx: Long): LogosDeliveryResult
  external fun logosDeliveryRelayPublish(
      ctx: Long,
      topic: String,
      wakuMsg: String,
      timeoutMs: Int
  ): LogosDeliveryResult
  external fun logosDeliveryRelaySubscribe(ctx: Long, topic: String): LogosDeliveryResult
  external fun logosDeliveryRelayUnsubscribe(ctx: Long, topic: String): LogosDeliveryResult
  external fun logosDeliverySetEventCallback(ctx: Long)

  init {
    EventCallbackManager.reactContext = reactContext
  }

  @ReactMethod
  fun setup(promise: Promise) {
    logosDeliverySetup()
    promise.resolve(null)
  }

  @ReactMethod
  fun new(config: ReadableMap, promise: Promise) {
    val configStr = stringifyReadableMap(config)
    val response = logosDeliveryNew(configStr)
    if (response.error) {
      promise.reject("logosdelivery_create_node", response.errorMessage)
    } else {
      // With this we just indicate to logos_delivery_ffi that we have registered a
      // closure, for this logosDeliveryPtr. Later once a message is received the
      // callback manager will receive both the logosDeliveryPtr and the message,
      // and it will use these values to emit a JS event
      logosDeliverySetEventCallback(response.ptr)

      promise.resolve(BigInteger.valueOf(response.ptr).toString())
    }
  }

  @ReactMethod
  fun start(ctx: String, promise: Promise) {
    val logosDeliveryPtr = BigInteger(ctx).toLong()
    val response = logosDeliveryStart(logosDeliveryPtr)
    if (response.error) {
      promise.reject("logosdelivery_start_node", response.message)
    } else {
      promise.resolve(null)
    }
  }

  @ReactMethod
  fun version(ctx: String, promise: Promise) {
    val logosDeliveryPtr = BigInteger(ctx).toLong()
    val response = logosDeliveryVersion(logosDeliveryPtr)
    if (response.error) {
      promise.reject("waku_version", response.message)
    } else {
      promise.resolve(response.message)
    }
  }

  @ReactMethod
  fun stop(ctx: String, promise: Promise) {
    val logosDeliveryPtr = BigInteger(ctx).toLong()
    val response = logosDeliveryStop(logosDeliveryPtr)
    if (response.error) {
      promise.reject("logosdelivery_stop_node", response.message)
    } else {
      promise.resolve(null)
    }
  }

  @ReactMethod
  fun destroy(ctx: String, promise: Promise) {
    val logosDeliveryPtr = BigInteger(ctx).toLong()
    val response = logosDeliveryDestroy(logosDeliveryPtr)
    if (response.error) {
      promise.reject("logosdelivery_destroy", response.message)
    } else {
      promise.resolve(null)
    }
  }

  @ReactMethod
  fun listenAddresses(ctx: String, promise: Promise) {
    val logosDeliveryPtr = BigInteger(ctx).toLong()
    val response = logosDeliveryListenAddresses(logosDeliveryPtr)
    if (response.error) {
      promise.reject("waku_listen_addresses", response.message)
    } else {
      promise.resolve(convertStringToArray(response.message))
    }
  }

  @ReactMethod
  fun connect(ctx: String, peerMultiAddr: String, timeoutMs: Int, promise: Promise) {
    val logosDeliveryPtr = BigInteger(ctx).toLong()
    val response = logosDeliveryConnect(logosDeliveryPtr, peerMultiAddr, timeoutMs)
    if (response.error) {
      promise.reject("waku_connect", response.message)
    } else {
      promise.resolve(null)
    }
  }

  @ReactMethod
  fun relaySubscribe(ctx: String, topic: String, promise: Promise) {
    val logosDeliveryPtr = BigInteger(ctx).toLong()
    val response = logosDeliveryRelaySubscribe(logosDeliveryPtr, topic)
    if (response.error) {
      promise.reject("waku_relay_subscribe", response.message)
    } else {
      promise.resolve(null)
    }
  }

  @ReactMethod
  fun relayUnsubscribe(ctx: String, topic: String, promise: Promise) {
    val logosDeliveryPtr = BigInteger(ctx).toLong()
    val response = logosDeliveryRelayUnsubscribe(logosDeliveryPtr, topic)
    if (response.error) {
      promise.reject("waku_relay_unsubscribe", response.message)
    } else {
      promise.resolve(null)
    }
  }

  @ReactMethod
  fun relayPublish(ctx: String, topic: String, msg: ReadableMap, timeoutMs: Int, promise: Promise) {
    val logosDeliveryPtr = BigInteger(ctx).toLong()
    val msgStr = stringifyReadableMap(msg)
    val response = logosDeliveryRelayPublish(logosDeliveryPtr, topic, msgStr, timeoutMs)
    if (response.error) {
      promise.reject("waku_relay_publish", response.message)
    } else {
      promise.resolve(null)
    }
  }

  @ReactMethod
  fun addListener(eventName: String) {
    // No impl required
  }

  @ReactMethod
  fun removeListeners(count: Int) {
    // No impl required
  }
}
