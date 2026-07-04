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

const WakuFactory = (() => {
  let isSetup = false;

  const eventEmitter = new NativeEventEmitter(NativeModules.WakuModule);
  class Waku {
    wakuPtr: Number;

    constructor(wakuPtr: Number) {
      this.wakuPtr = wakuPtr;
    }

    async destroy(): Promise<void> {
      await NativeModules.WakuModule.destroy(this.wakuPtr);
    }

    async start(): Promise<void> {
      return NativeModules.WakuModule.start(this.wakuPtr);
    }

    async stop(): Promise<void> {
      return NativeModules.WakuModule.stop(this.wakuPtr);
    }

    async version(): Promise<String> {
      return NativeModules.WakuModule.version(this.wakuPtr);
    }

    async listenAddresses(): Promise<Array<String>> {
      let addresses = await NativeModules.WakuModule.listenAddresses(
        this.wakuPtr,
      );
      return addresses;
    }

    async connect(peerMultiaddr: String, timeoutMs: Number): Promise<void> {
      return NativeModules.WakuModule.connect(
        this.wakuPtr,
        peerMultiaddr,
        timeoutMs,
      );
    }

    async relaySubscribe(pubsubTopic: String): Promise<void> {
      return NativeModules.WakuModule.relaySubscribe(this.wakuPtr, pubsubTopic);
    }

    async relayUnsubscribe(pubsubTopic: String): Promise<void> {
      return NativeModules.WakuModule.relayUnsubscribe(
        this.wakuPtr,
        pubsubTopic,
      );
    }

    // TODO: Use a type instead of `any`
    async relayPublish(
      pubsubTopic: string,
      msg: any,
      timeoutMs: Number,
    ): Promise<String> {
      return NativeModules.WakuModule.relayPublish(
        this.wakuPtr,
        pubsubTopic,
        msg,
        timeoutMs,
      );
    }

    onEvent(cb: (event: any) => void): EmitterSubscription {
      return eventEmitter.addListener('wakuEvent', evt => {
        if (evt.wakuPtr === this.wakuPtr) {
          cb(JSON.parse(evt.event));
        }
      });
    }
  }

  async function createInstance(config: any) {
    if (!isSetup) {
      console.debug('initializing waku library');
      await NativeModules.WakuModule.setup();
      isSetup = true;
      alert('waku instance created!');
    }

    let wakuPtr = await NativeModules.WakuModule.new(config);
    return new Waku(wakuPtr);
  }

  // Expose the factory method
  return {
    createInstance,
    Waku,
  };
})();

function App(): React.JSX.Element {
  const isDarkMode = useColorScheme() === 'dark';

  const backgroundStyle = {
    backgroundColor: isDarkMode ? Colors.darker : Colors.lighter,
  };

  var waku: Waku;

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
    waku = await WakuFactory.createInstance(config);
  };

  const onClickStart = async () => {
    await waku.start();
    alert('start executed succesfully');
  };

  const onClickVersion = async () => {
    let version = await waku.version();
    alert(version);
  };

  const onClickListenAddresses = async () => {
    let addresses = await waku.listenAddresses();
    alert(addresses[0]);
  };

  const onClickStop = async () => {
    await waku.stop();
    alert('stopped!');
  };

  const onClickDestroy = async () => {
    await waku.destroy();
    alert('destroyed!');
  };

  const onClickConnect = async () => {
    let result = await waku.connect(
      '/ip4/127.0.0.1/tcp/48117/p2p/16Uiu2HAmVrsyU3y3pQYuSEyaqrBgevQeshp7YZsL8rY3nWb2yWD5',
      0,
    );
    alert(
      'connected? (TODO: bindings function do not return connection attempt status)',
    );
  };

  const onClickSubscribe = async () => {
    await waku.relaySubscribe('test');
    alert('subscribed to test');
  };

  const onClickUnsubscribe = async () => {
    await waku.relayUnsubscribe('test');
    alert('unsubscribed from test');
  };

  const onClickSetEventCallback = async () => {
    const eventSubs = waku.onEvent((event: any) => {
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
    let hash = await waku.relayPublish(pubsubTopic, msg, 0);
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
