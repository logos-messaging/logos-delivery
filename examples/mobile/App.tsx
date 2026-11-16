/* eslint-disable no-alert */
/**
 * Sample React Native App
 * https://github.com/facebook/react-native
 *
 * @format
 */

import React from 'react';
import type {PropsWithChildren} from 'react';
import {
  SafeAreaView,
  ScrollView,
  StatusBar,
  StyleSheet,
  Text,
  useColorScheme,
  View,
} from 'react-native';

import {Colors} from 'react-native/Libraries/NewAppScreen';
import {
  NativeEventEmitter,
  NativeModules,
  EmitterSubscription,
  Button,
} from 'react-native';

type SectionProps = PropsWithChildren<{
  title: string;
}>;

function Section({children, title}: SectionProps): React.JSX.Element {
  const isDarkMode = useColorScheme() === 'dark';
  return (
    <View style={styles.sectionContainer}>
      <Text
        style={[
          styles.sectionTitle,
          {
            color: isDarkMode ? Colors.white : Colors.black,
          },
        ]}>
        {title}
      </Text>
      <Text
        style={[
          styles.sectionDescription,
          {
            color: isDarkMode ? Colors.light : Colors.dark,
          },
        ]}>
        {children}
      </Text>
    </View>
  );
}

const LogosDeliveryFactory = (() => {
  let isSetup = false;

  const eventEmitter = new NativeEventEmitter(NativeModules.LogosDeliveryModule);
  class LogosDelivery {
    logosDeliveryPtr: Number;

    constructor(logosDeliveryPtr: Number) {
      this.logosDeliveryPtr = logosDeliveryPtr;
    }

    async destroy(): Promise<void> {
      await NativeModules.LogosDeliveryModule.destroy(this.logosDeliveryPtr);
    }

    async start(): Promise<void> {
      return NativeModules.LogosDeliveryModule.start(this.logosDeliveryPtr);
    }

    async stop(): Promise<void> {
      return NativeModules.LogosDeliveryModule.stop(this.logosDeliveryPtr);
    }

    async version(): Promise<String> {
      return NativeModules.LogosDeliveryModule.version(this.logosDeliveryPtr);
    }

    async listenAddresses(): Promise<Array<String>> {
      let addresses = await NativeModules.LogosDeliveryModule.listenAddresses(
        this.logosDeliveryPtr,
      );
      return addresses;
    }

    async connect(peerMultiaddr: String, timeoutMs: Number): Promise<void> {
      return NativeModules.LogosDeliveryModule.connect(
        this.logosDeliveryPtr,
        peerMultiaddr,
        timeoutMs,
      );
    }

    async relaySubscribe(pubsubTopic: String): Promise<void> {
      return NativeModules.LogosDeliveryModule.relaySubscribe(this.logosDeliveryPtr, pubsubTopic);
    }

    async relayUnsubscribe(pubsubTopic: String): Promise<void> {
      return NativeModules.LogosDeliveryModule.relayUnsubscribe(
        this.logosDeliveryPtr,
        pubsubTopic,
      );
    }

    // TODO: Use a type instead of `any`
    async relayPublish(
      pubsubTopic: string,
      msg: any,
      timeoutMs: Number,
    ): Promise<String> {
      return NativeModules.LogosDeliveryModule.relayPublish(
        this.logosDeliveryPtr,
        pubsubTopic,
        msg,
        timeoutMs,
      );
    }

    onEvent(cb: (event: any) => void): EmitterSubscription {
      return eventEmitter.addListener('logosDeliveryEvent', evt => {
        if (evt.logosDeliveryPtr === this.logosDeliveryPtr) {
          cb(JSON.parse(evt.event));
        }
      });
    }
  }

  async function createInstance(config: any) {
    if (!isSetup) {
      console.debug('initializing logosDelivery library');
      await NativeModules.LogosDeliveryModule.setup();
      isSetup = true;
      alert('logosDelivery instance created!');
    }

    let logosDeliveryPtr = await NativeModules.LogosDeliveryModule.new(config);
    return new LogosDelivery(logosDeliveryPtr);
  }

  // Expose the factory method
  return {
    createInstance,
    LogosDelivery,
  };
})();

function App(): React.JSX.Element {
  const isDarkMode = useColorScheme() === 'dark';

  const backgroundStyle = {
    backgroundColor: isDarkMode ? Colors.darker : Colors.lighter,
  };

  var logosDelivery: LogosDelivery;

  const onClickNew = async () => {
    const config = {
      mode: 'Core',
      messagingOverrides: {
        'listen-address': '0.0.0.0',
        'tcp-port': 42342,
        nodekey:
          '1122334455667788990011223344556677889900112233445566778899000022',
      },
    };
    logosDelivery = await LogosDeliveryFactory.createInstance(config);
  };

  const onClickStart = async () => {
    await logosDelivery.start();
    alert('start executed succesfully');
  };

  const onClickVersion = async () => {
    let version = await logosDelivery.version();
    alert(version);
  };

  const onClickListenAddresses = async () => {
    let addresses = await logosDelivery.listenAddresses();
    alert(addresses[0]);
  };

  const onClickStop = async () => {
    await logosDelivery.stop();
    alert('stopped!');
  };

  const onClickDestroy = async () => {
    await logosDelivery.destroy();
    alert('destroyed!');
  };

  const onClickConnect = async () => {
    let result = await logosDelivery.connect(
      '/ip4/127.0.0.1/tcp/48117/p2p/16Uiu2HAmVrsyU3y3pQYuSEyaqrBgevQeshp7YZsL8rY3nWb2yWD5',
      0,
    );
    alert(
      'connected? (TODO: bindings function do not return connection attempt status)',
    );
  };

  const onClickSubscribe = async () => {
    await logosDelivery.relaySubscribe('test');
    alert('subscribed to test');
  };

  const onClickUnsubscribe = async () => {
    await logosDelivery.relayUnsubscribe('test');
    alert('unsubscribed from test');
  };

  const onClickSetEventCallback = async () => {
    const eventSubs = logosDelivery.onEvent((event: any) => {
      console.log(event);
      alert('received a message');
    });
    // TODO: eventSubs.remove() should be used to avoid a mem leak.

    alert("event callback set");
  };

  const onClickPublish = async () => {
    const pubsubTopic = 'test';
    const msg = {
      payload: 'aGVsbG8',
      contentTopic: 'test',
      timestamp: 0,
      version: 0,
    };
    let hash = await logosDelivery.relayPublish(pubsubTopic, msg, 0);
    alert('published - msgHash: ' + hash);
  };

  return (
    <SafeAreaView style={backgroundStyle}>
      <StatusBar
        barStyle={isDarkMode ? 'light-content' : 'dark-content'}
        backgroundColor={backgroundStyle.backgroundColor}
      />
      <ScrollView
        contentInsetAdjustmentBehavior="automatic"
        style={backgroundStyle}>
        <View
          style={{
            backgroundColor: isDarkMode ? Colors.black : Colors.white,
          }}>
          <Section>
            <Button title="New" color="#841584" onPress={onClickNew} />
          </Section>
          <Section>
            <Button title="Start" color="#841584" onPress={onClickStart} />
          </Section>
          <Section>
            <Button title="Version" color="#841584" onPress={onClickVersion} />
          </Section>
          <Section>
            <Button
              title="SetEventCallback"
              color="#841584"
              onPress={onClickSetEventCallback}
            />
          </Section>
          <Section>
            <Button
              title="ListenAddresses"
              color="#841584"
              onPress={onClickListenAddresses}
            />
          </Section>
          <Section>
            <Button title="Connect" color="#841584" onPress={onClickConnect} />
          </Section>
          <Section>
            <Button
              title="Subscribe"
              color="#841584"
              onPress={onClickSubscribe}
            />
          </Section>
          <Section>
            <Button title="Publish" color="#841584" onPress={onClickPublish} />
          </Section>
          <Section>
            <Button
              title="Unsubscribe"
              color="#841584"
              onPress={onClickUnsubscribe}
            />
          </Section>
          <Section>
            <Button title="Stop" color="#841584" onPress={onClickStop} />
          </Section>
          <Section>
            <Button title="Destroy" color="#841584" onPress={onClickDestroy} />
          </Section>
        </View>
      </ScrollView>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  sectionContainer: {
    marginTop: 32,
    paddingHorizontal: 24,
  },
  sectionTitle: {
    fontSize: 24,
    fontWeight: '600',
  },
  sectionDescription: {
    marginTop: 8,
    fontSize: 18,
    fontWeight: '400',
  },
  highlight: {
    fontWeight: '700',
  },
});

export default App;
